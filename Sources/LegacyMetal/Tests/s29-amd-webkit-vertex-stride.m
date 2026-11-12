// s29-amd-webkit-vertex-stride (AMDBronzeCompat item 6): for a draw of one vertex, WebKit's WebGPU copies the pipeline with the
// stride set to the end of the last attribute, 2 for snorm8x2. The 12.5 AMD driver refuses a stride that isn't a multiple of 4,
// WebKit then draws with no pipeline set, and the driver crashes, taking Safari's GPU process with it (WebGPU CTS
// api,validation,encoding,cmds,render,draw:vertex_buffer_OOB). The fix only applies in WebKit's processes, so this calls itself
// one before Metal loads. It makes that pipeline and checks the draw reads the vertex.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct In { float2 a [[attribute(0)]]; };\n"
    "struct Out { float4 position [[position]]; float size [[point_size]]; float2 a; };\n"
    "vertex Out vs(In in [[stage_in]]) { Out o; o.position = float4(0, 0, 0, 1); o.size = 4; o.a = in.a; return o; }\n"
    "fragment float4 fs(Out in [[stage_in]]) { return float4(in.a, 0, 1); }\n";

int main(int argc, char **argv) {
    setprogname("com.apple.WebKit.s29");
    @autoreleasepool {
        const char *bug = "s29-amd-webkit-vertex-stride";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
        p.vertexFunction = [lib newFunctionWithName:@"vs"];
        p.fragmentFunction = [lib newFunctionWithName:@"fs"];
        p.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatUChar2Normalized;
        vd.attributes[0].bufferIndex = 1;
        vd.layouts[1].stride = 2;
        p.vertexDescriptor = vd;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:p error:&err];
        if (!ps) return FAIL(bug, "%s: stride 2: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        const uint8_t vertex[4] = {51, 204};
        id<MTLBuffer> vb = [dev newBufferWithBytes:vertex length:sizeof vertex options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps];
        [e setVertexBuffer:vb offset:0 atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
        [e endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b synchronizeResource:target];
        [b endEncoding];
        reproRun(cb);
        uint8_t px[4] = {0};
        [target getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(2, 2, 1, 1) mipmapLevel:0];
        if (px[0] != 51 || px[1] != 204) return FAIL(bug, "%s: vertex read as %u %u, want 51 204", dev.name.UTF8String, px[0], px[1]);
        return PASS(bug, "%s: stride 2 in WebKit's processes gives a pipeline that reads the vertex", dev.name.UTF8String);
    }
}
