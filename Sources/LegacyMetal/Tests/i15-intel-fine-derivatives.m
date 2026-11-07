// i15-intel-fine-derivatives (Intel adapter, IntelTextureAtomics.dylib): dfdx / dfdy must give each row (column) of a
// 2x2 pixel quad its own difference, as Apple GPUs do. The IGIL back end writes them as GRADIENT_X / GRADIENT_Y, which
// the Intel compiler evaluates coarse (one difference per quad), so WGSL's dpdxFine, dpdyFine and fwidthFine (compiled
// to dfdx / dfdy by Tint) were wrong wherever the rows differ (WebGPU CTS: 8 of 8 cases each). Draws v = x * y over 4x4
// pixels and writes dfdx(v) and dfdy(v): at pixel centers (x, y) those are y and x, which differ between the two rows
// and columns of every quad.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 fullScreen(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment float2 gradients(float4 pos [[position]]) { float v = pos.x * pos.y; return float2(dfdx(v), dfdy(v)); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i15-intel-fine-derivatives";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"fullScreen"];
        pd.fragmentFunction = [lib newFunctionWithName:@"gradients"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG32Float;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        float px[4 * 4 * 2];
        [target getBytes:px bytesPerRow:4 * 8 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
        for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
            float dx = px[(y * 4 + x) * 2], dy = px[(y * 4 + x) * 2 + 1], wantDx = y + 0.5f, wantDy = x + 0.5f;
            if (fabsf(dx - wantDx) > 1e-3f || fabsf(dy - wantDy) > 1e-3f)
                return FAIL(bug, "%s: pixel (%d,%d): dfdx %.3f, dfdy %.3f, want %.3f, %.3f (fine derivatives)", name, x, y, dx, dy, wantDx, wantDy);
        }
        return PASS(bug, "%s: dfdx / dfdy differ per row / column of each quad (fine)", name);
    }
}
