// i74-intel-ivb-ldst-walk: the adapter's faster isValueUsed walk on Ivy Bridge must find each load's buffer; the stock
// walk is right but slow on big shaders. Fix: IntelTextureAtomics INTEL_VALUE_USED_FIX.
// Checks: FIELDS (800) floats from each of three buffers summed; build within LIMIT (60) s. Argument: GPU name.
#import "repro.h"
#include <mach/mach_time.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i74-intel-ivb-ldst-walk";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        int fields = getenv("FIELDS") ? atoi(getenv("FIELDS")) : 800;
        double limit = getenv("LIMIT") ? atof(getenv("LIMIT")) : 60;
        NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint id [[vertex_id]]) { return float4(id & 1 ? 1.0 : -1.0, id & 2 ? 1.0 : -1.0, 0.5, 1); }\n"
            "fragment float4 f(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device const float *u [[buffer(2)]]) {\n"
            "    float s = 0;\n"];
        for (int i = 0; i < fields; i++) [src appendFormat:@"    s += a[%d] + b[%d];\n    s += u[%d] * %d.0f;\n", 2 * i, 2 * i, 2 * i, i % 7 + 1];
        [src appendString:@"    return float4(s, 0, 0, 1);\n}\n"];
        NSError *err = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.fastMathEnabled = NO;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:options error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        uint64_t t0 = mach_absolute_time();
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        double seconds = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9;
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        float *values = calloc(2 * fields, sizeof(float));
        double want = 0;
        for (int i = 0; i < fields; i++) values[2 * i] = (float)(i % 13) * 0.25f, want += values[2 * i] * (i % 7 + 1);
        id<MTLBuffer> u = [dev newBufferWithBytes:values length:sizeof(float) * 2 * fields options:MTLResourceStorageModeShared];
        id<MTLBuffer> zeros = [dev newBufferWithLength:sizeof(float) * 2 * fields options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re setFragmentBuffer:zeros offset:0 atIndex:0];
        [re setFragmentBuffer:zeros offset:0 atIndex:1];
        [re setFragmentBuffer:u offset:0 atIndex:2];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:target];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        float got = 0;
        [target getBytes:&got bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        if (fabs(got - want) > fabs(want) * 1e-4)
            return FAIL(bug, "%s: fragment function reading %d floats of each of three buffers rendered %g, want %g", dev.name.UTF8String, fields, got, want);
        if (seconds > limit)
            return FAIL(bug, "%s: a fragment function reading %d floats of each of three buffers took %.1f s to build (limit %.0f s)", dev.name.UTF8String,
                        fields, seconds, limit);
        return PASS(bug, "%s: a fragment function reading %d floats of each of three buffers built in %.1f s and renders the right sum",
                    dev.name.UTF8String, fields, seconds);
    }
}
