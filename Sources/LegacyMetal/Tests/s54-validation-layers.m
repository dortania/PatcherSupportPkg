// s54-validation-layers (MetalOldCompat item 41): Metal's validation layers on MetalOld. With MTL_DEBUG_LAYER=1, Tahoe's and
// Sequoia's MetalTools crashed on every compute dispatch (a call into a placeholder the Metal wrapper exports as data),
// asserted "Bicubic filtering of 16-bit normalized values is not supported" on an indirect command buffer, and rejected a
// matching render pipeline with nonsense values ("colorSampleCount (1065353216)"), aborting the process; with
// MTL_SHADER_VALIDATION=1, pipeline creation threw. wgpu's GPU tests set both at run time and aborted on this stack. Sets
// both the same way, then makes a compute pipeline and checks a dispatch, draws with a render pipeline in a render pass,
// and makes wgpu's indirect command buffer (Mac2 GPUs). The shim switches the layers off before the device is made, so the steps run
// without validation. Stock OCLP / no-op shim: abort. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s54-validation-layers";
        if (!reproOnMetalOld()) return SKIP(bug, "MetalOldCompat needs OCLP's MetalOld wrapper");
        setenv("MTL_DEBUG_LAYER", "1", 1);
        setenv("MTL_SHADER_VALIDATION", "1", 1);
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void k(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[t] = t * 3u + 1u; }\n"
            "vertex float4 v(uint i [[vertex_id]]) { return float4(float(i & 1) * 4 - 1, float(i >> 1) * 4 - 1, 0, 1); }\n"
            "fragment float4 f() { return float4(1, 0, 0, 1); }\n";
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!cps) return FAIL(bug, "%s: compute pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLBuffer> out = [dev newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cps];
        [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(256, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: compute command buffer failed", dev.name.UTF8String);
        const uint32_t *o = out.contents;
        for (uint32_t i = 0; i < 256; i++)
            if (o[i] != i * 3 + 1) return FAIL(bug, "%s: dispatch wrote %u at %u", dev.name.UTF8String, o[i], i);

        MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
        rpd.vertexFunction = [lib newFunctionWithName:@"v"];
        rpd.fragmentFunction = [lib newFunctionWithName:@"f"];
        rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        rpd.supportIndirectCommandBuffers = YES;
        id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
        if (!rps) return FAIL(bug, "%s: render pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:rps];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: render command buffer failed", dev.name.UTF8String);
        uint32_t pixel = 0;
        [target getBytes:&pixel bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        if (pixel != 0xff0000ff) return FAIL(bug, "%s: drawn pixel is %08x, not ff0000ff", dev.name.UTF8String, pixel);

        MTLIndirectCommandBufferDescriptor *icbd = [MTLIndirectCommandBufferDescriptor new];
        icbd.inheritPipelineState = YES;
        icbd.inheritBuffers = YES;
        icbd.commandTypes = MTLIndirectCommandTypeDraw;
        icbd.maxVertexBufferBindCount = 31;
        icbd.maxFragmentBufferBindCount = 0;
        id<MTLIndirectCommandBuffer> icb = [dev newIndirectCommandBufferWithDescriptor:icbd maxCommandCount:1 options:MTLResourceStorageModePrivate];
        BOOL mac2 = [dev supportsFamily:MTLGPUFamilyMac2];  // indirect command buffers need it (the Iris Pro is Mac1)
        if (mac2 && !icb) return FAIL(bug, "%s: no indirect command buffer", dev.name.UTF8String);
        return PASS(bug, "%s: with MTL_DEBUG_LAYER and MTL_SHADER_VALIDATION set, a dispatch, a draw%s work", dev.name.UTF8String,
                    mac2 ? " and an indirect command buffer" : " (no indirect command buffers on this GPU family)");
    }
}
