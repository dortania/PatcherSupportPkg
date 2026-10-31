// s07-vertex-descriptor (MetalOldCompat item 7): a vertex descriptor with a MTLVertexStepFunctionConstant layout, as
// Blender uses for default attributes. The current compiler and MetalOld serialize vertex descriptors with layout
// records of different sizes, so MetalOld misreads the layouts: pipeline creation fails with "Buffer stride is not a
// multiple of 4 bytes", or the attributes are fetched wrongly. Draws one triangle (positions per vertex in buffer 1,
// colour + uv constant in buffer 2) and checks the pixel.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VI { float3 pos [[attribute(0)]]; float4 col [[attribute(2)]]; float2 uv [[attribute(3)]]; };\n"
    "struct VO { float4 pos [[position]]; float4 col; };\n"
    "vertex VO vs(VI in [[stage_in]]) { VO o; o.pos = float4(in.pos, 1); o.col = in.col + float4(in.uv, 0, 0); return o; }\n"
    "fragment float4 fs(VO in [[stage_in]]) { return in.col; }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s07-vertex-descriptor";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "library: %s", err.localizedDescription.UTF8String);
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat3; vd.attributes[0].bufferIndex = 1;
        vd.layouts[1].stride = 12;
        vd.attributes[2].format = MTLVertexFormatFloat4; vd.attributes[2].bufferIndex = 2;
        vd.attributes[3].format = MTLVertexFormatFloat2; vd.attributes[3].bufferIndex = 2; vd.attributes[3].offset = 16;
        vd.layouts[2].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[2].stride = 24; vd.layouts[2].stepRate = 0;
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.vertexDescriptor = vd;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!ps) return FAIL(bug, "%s: render pipeline with a constant-step layout: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        float pos[9] = {-1, -1, 0, 3, -1, 0, -1, 3, 0};
        float constant[6] = {0.25f, 0.5f, 0.0f, 1.0f, 0.5f, 0.25f};  // colour (.25 .5 0 1) + uv (.5 .25) -> (.75 .75 0 1)
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps];
        [e setVertexBytes:pos length:sizeof pos atIndex:1];
        [e setVertexBytes:constant length:sizeof constant atIndex:2];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b synchronizeResource:rt];
        [b endEncoding];
        reproRun(cb);
        uint8_t px[4];
        [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        if (abs(px[0] - 191) > 2 || abs(px[1] - 191) > 2 || px[2] > 2 || px[3] < 253)
            return FAIL(bug, "%s: pixel %d %d %d %d, want 191 191 0 255", dev.name.UTF8String, px[0], px[1], px[2], px[3]);
        return PASS(bug, "%s: constant-step vertex layout fetched correctly", dev.name.UTF8String);
    }
}
