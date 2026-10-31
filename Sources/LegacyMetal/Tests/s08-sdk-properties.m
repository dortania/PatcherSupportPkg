// s08-sdk-properties (MetalOldCompat item 8): properties and encoder calls from the macOS 13.3-15 SDKs that MetalOld
// (13.2) lacks. Chromium's ANGLE calls -[MTLCompileOptions setMathMode:] for every shader (the GPU process aborts with
// "unrecognized selector"); MoltenVK / wgpu use the attributeStride encoder calls; macOS 15 apps read
// shaderValidation; render encoders get object/mesh stage bindings even on GPUs without mesh shaders (MetalOld's
// _MTLCommandEncoder has them as throwing stubs). Each call runs in a child process.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"
#import <objc/message.h>

static const char *const kCalls[] = {"mathMode", "shaderValidation", "attributeStride", "objectBuffer"};

static int child(int argc, char **argv, const char *mode) {
    id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
    if (!strcmp(mode, "mathMode")) {
        MTLCompileOptions *o = [MTLCompileOptions new];
        if (@available(macOS 15.0, *)) { o.mathMode = MTLMathModeSafe; return o.mathMode == MTLMathModeSafe ? 0 : 6; }
        return 0;
    }
    if (!strcmp(mode, "shaderValidation")) {
        if (@available(macOS 15.0, *)) { (void)[MTLRenderPipelineDescriptor new].shaderValidation; (void)[MTLComputePipelineDescriptor new].shaderValidation; }
        return 0;
    }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct VO { float4 p [[position]]; };\n"
        "vertex VO vs(uint v [[vertex_id]], const device float4 *b [[buffer(0)]]) { VO o; o.p = b[v]; return o; }\n"
        "fragment float4 fs() { return float4(1); }\n" options:nil error:&err];
    if (!lib) return 3;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];
    id<MTLBuffer> buf = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    if (!strcmp(mode, "attributeStride")) {
        if (@available(macOS 14.0, *)) [e setVertexBuffer:buf offset:0 attributeStride:16 atIndex:0];
    } else if (!strcmp(mode, "objectBuffer")) {
        if (@available(macOS 13.0, *)) [e setObjectBuffer:buf offset:0 atIndex:0];
        [e setVertexBuffer:buf offset:0 atIndex:0];
    }
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    return reproRun(cb) ? 0 : 7;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *mode = reproChildMode(argc, argv);
        if (mode) return child(argc, argv, mode);
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP("s08-sdk-properties", "no such GPU");
        char failed[256] = "";
        for (int i = 0; i < 4; i++) {
            int status = reproRunChild(argc, argv, kCalls[i]);
            if (status) snprintf(failed + strlen(failed), sizeof failed - strlen(failed), "%s%s: %s", *failed ? "; " : "", kCalls[i], reproChildStatus(status));
        }
        if (*failed) return FAIL("s08-sdk-properties", "%s: %s", dev.name.UTF8String, failed);
        return PASS("s08-sdk-properties", "%s: setMathMode, shaderValidation, attributeStride and object-stage calls work", dev.name.UTF8String);
    }
}
