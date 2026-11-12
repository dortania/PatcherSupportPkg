// s47-amd-stencil-only-attachment (AMDBronzeCompat item 12): a depth-stencil texture attached as the stencil attachment
// alone (no depth attachment) must test and write the stencil that blits put there. With only stencil attached, the
// 12.5 AMD driver programs the depth unit's stencil-only state, which leaves part of the surface setup at what a depth
// attachment would have set: on textures up to 32 texels wide the stencil test sees about half of the texels (a 32x16
// Depth32Float_Stencil8 texture: 256 of 512), and it writes stencil there the same way. Attaching the texture as depth too
// makes it right. ANGLE attaches a packed depth-stencil buffer that way when GL only binds it as GL_STENCIL_ATTACHMENT.
// Blits a stencil value per row into 32x16 textures (Depth32Float_Stencil8, Depth24Unorm_Stencil8 where supported, and
// level 1 of a 64x64 one), counts the pixels an EQUAL test passes for each value with only stencil attached, then writes
// stencil 0x5A with a REPLACE draw (stencil only) and reads it back with a blit.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { float2 t = float2((id << 1) & 2, id & 2); return float4(t * 2 - 1, 0, 1); }\n"
    "fragment float4 f() { return float4(1); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s47-amd-stencil-only-attachment";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        MTLDepthStencilDescriptor *equal = [MTLDepthStencilDescriptor new], *replace = [MTLDepthStencilDescriptor new];
        equal.frontFaceStencil.stencilCompareFunction = MTLCompareFunctionEqual;
        equal.backFaceStencil = equal.frontFaceStencil;
        replace.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
        replace.backFaceStencil = replace.frontFaceStencil;
        id<MTLDepthStencilState> equalState = [dev newDepthStencilStateWithDescriptor:equal], replaceState = [dev newDepthStencilStateWithDescriptor:replace];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        struct { MTLPixelFormat format; int size, level; const char *what; } cases[] = {
            {MTLPixelFormatDepth32Float_Stencil8, 32, 0, "Depth32Float_Stencil8 32x16"},
            {MTLPixelFormatDepth24Unorm_Stencil8, 32, 0, "Depth24Unorm_Stencil8 32x16"},
            {MTLPixelFormatDepth32Float_Stencil8, 64, 1, "Depth32Float_Stencil8 64x32, level 1"},
        };
        int ran = 0;
        for (int c = 0; c < 3; c++) {
            if (cases[c].format == MTLPixelFormatDepth24Unorm_Stencil8 && !dev.depth24Stencil8PixelFormatSupported) continue;
            pd.stencilAttachmentPixelFormat = cases[c].format;
            pd.depthAttachmentPixelFormat = MTLPixelFormatInvalid;  // a stencil-only pipeline, as the app has
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[c].format width:cases[c].size
                                                                                         height:cases[c].size / 2 mipmapped:cases[c].level > 0];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            int w = cases[c].size >> cases[c].level, h = (cases[c].size / 2) >> cases[c].level, level = cases[c].level;
            id<MTLBuffer> rows = [dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
            for (int y = 0; y < h; y++) memset((uint8_t *)rows.contents + y * w, 0x10 + y, w);
            MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:w height:h mipmapped:NO];
            cd.usage = MTLTextureUsageRenderTarget;
            cd.storageMode = MTLStorageModePrivate;
            id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
            id<MTLBuffer> drawn = [dev newBufferWithLength:w * h * (h + 1) options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromBuffer:rows sourceOffset:0 sourceBytesPerRow:w sourceBytesPerImage:w * h sourceSize:MTLSizeMake(w, h, 1) toTexture:t
                destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0) options:MTLBlitOptionStencilFromDepthStencil];
            [b endEncoding];
            for (int y = 0; y <= h; y++) {  // value 0x10 + y for each row, then the REPLACE write (y == h)
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = color;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.stencilAttachment.texture = t;
                rp.stencilAttachment.level = level;
                rp.stencilAttachment.loadAction = MTLLoadActionLoad;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:ps];
                [enc setDepthStencilState:y < h ? equalState : replaceState];
                [enc setStencilReferenceValue:y < h ? 0x10 + y : 0x5A];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
                if (y < h) {
                    b = [cb blitCommandEncoder];
                    [b copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                              toBuffer:drawn destinationOffset:w * h * y destinationBytesPerRow:w destinationBytesPerImage:w * h];
                    [b endEncoding];
                }
            }
            id<MTLBuffer> back = [dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
            b = [cb blitCommandEncoder];
            [b copyFromTexture:t sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:back
                destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:w * h options:MTLBlitOptionStencilFromDepthStencil];
            [b endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, cases[c].what);
            int passed = 0, misplaced = 0, written = 0;
            for (int y = 0; y < h; y++)
                for (int i = 0; i < w * h; i++) {
                    bool lit = ((uint8_t *)drawn.contents)[w * h * y + i] != 0;
                    if (lit && i / w == y) passed++;
                    else if (lit) misplaced++;
                }
            for (int i = 0; i < w * h; i++) written += ((uint8_t *)back.contents)[i] == 0x5A;
            if (passed != w * h || misplaced || written != w * h)
                return FAIL(bug, "%s: %s with only stencil attached: EQUAL passed %d of %d texels (%d elsewhere), REPLACE wrote %d of %d", name,
                            cases[c].what, passed, w * h, misplaced, written, w * h);
            ran++;
        }
        return PASS(bug, "%s: stencil-only attachments of depth-stencil textures test and write every texel (%d cases)", name, ran);
    }
}
