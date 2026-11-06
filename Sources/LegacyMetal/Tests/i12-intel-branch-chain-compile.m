// i12-intel-branch-chain-compile (Intel adapter, IntelTextureAtomics.dylib): a vertex function made of chains of short
// branches (`if (a && b && c ...)` over many values, each chain falling through to a shared else) takes exponential time in
// the 12.x Intel back end (iCBE register allocation's structural analysis): 4 such checks compile in 2 s, 8 in more than ten
// minutes. Chrome's GPU process is killed by its watchdog while it waits (WebGPU CTS
// shader,execution,robust_access_vertex, which checks each of up to 12 vertex attributes that way). A vertex function
// checks 12 float4 values read from 12 buffers (each component one of five allowed values, else all zero) and writes
// whether they passed; the pipeline has to build within 60 s and draw the right answers for four vertices.
// Stock OCLP: FAIL (time-out). Fixed: PASS. Argument: GPU name substring (default: Intel). I12_VALUES=<n> changes the count.
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i12-intel-branch-chain-compile";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        int count = getenv("I12_VALUES") ? atoi(getenv("I12_VALUES")) : 12;
        if (count < 1 || count > 24) count = 12;
        NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "static bool allowed(float f) { return f == 0 || f == 991 || f == 685 || f == 446 || f == 175; }\n"
            "static bool valid(float4 v) {\n"
            "  if (allowed(v.x) && allowed(v.y) && allowed(v.z) && allowed(v.w)) return true;\n"
            "  return v.x == 0 && v.y == 0 && v.z == 0 && (v.w == 0 || v.w == 1); }\n"
            "static float4 fetch(const device float *b, uint n, uint i) {\n"
            "  return float4(b[min(i * 4, n - 1)], b[min(i * 4 + 1, n - 1)], b[min(i * 4 + 2, n - 1)], b[min(i * 4 + 3, n - 1)]); }\n"
            "struct out_t { float4 position [[position]]; float point_size [[point_size]]; float ok; };\n"
            "vertex out_t v(uint id [[vertex_id]], constant uint *n [[buffer(0)]]"];
        for (int k = 0; k < count; k++) [src appendFormat:@", const device float *b%d [[buffer(%d)]]", k, k + 1];
        [src appendString:@") {\n  bool ok = false;\n  "];
        for (int k = 0; k < count - 1; k++) [src appendFormat:@"if (valid(fetch(b%d, n[%d], id))) ", k, k];
        [src appendFormat:@"if (id < 4 && valid(fetch(b%d, n[%d], id))) ok = true;\n", count - 1, count - 1];
        [src appendString:@"  out_t o; o.position = float4((float(id) + 0.5) / 2 - 1, 0, 0, 1); o.point_size = 1; o.ok = ok ? 1 : 0; return o; }\n"
            "fragment float4 f(out_t i [[stage_in]]) { return float4(i.ok); }\n"];
        [src appendString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: no library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        __block id<MTLRenderPipelineState> ps = nil;
        __block NSError *buildError = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSDate *start = [NSDate date];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{  // synchronous: the asynchronous call bypasses localcc
            NSError *e = nil;
            ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
            buildError = e;
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)))
            return FAIL(bug, "%s: the pipeline for %d chained checks didn't build in 60 s", dev.name.UTF8String, count);
        double seconds = -start.timeIntervalSinceNow;
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, buildError.localizedDescription.UTF8String);
        // vertex 0: every value allowed; 1: one component not allowed (and not zero); 2: one value (0, 0, 0, 1), the rest
        // allowed; 3: one value (0, 0, 0, 2)
        static const float kAllowed[5] = {0, 991, 685, 446, 175};
        id<MTLBuffer> lengths = [dev newBufferWithLength:4 * count options:MTLResourceStorageModeShared];
        NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray array];
        for (int k = 0; k < count; k++) {
            float values[16];
            for (int i = 0; i < 16; i++) values[i] = kAllowed[(i + k) % 5];
            if (k == count / 2) {
                values[4 + 2] = 5;
                values[8] = values[9] = values[10] = 0, values[11] = 1;
                values[12] = values[13] = values[14] = 0, values[15] = 2;
            }
            ((uint32_t *)lengths.contents)[k] = 16;
            [buffers addObject:[dev newBufferWithBytes:values length:sizeof values options:MTLResourceStorageModeShared]];
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setVertexBuffer:lengths offset:0 atIndex:0];
        for (int k = 0; k < count; k++) [enc setVertexBuffer:buffers[k] offset:0 atIndex:k + 1];
        [enc drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:4];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        float got[4];
        [target getBytes:got bytesPerRow:sizeof got fromRegion:MTLRegionMake2D(0, 0, 4, 1) mipmapLevel:0];
        static const float kWant[4] = {1, 0, 1, 0};
        for (int i = 0; i < 4; i++)
            if (got[i] != kWant[i])
                return FAIL(bug, "%s: vertex %d wrote %g, want %g (pipeline built in %.1f s)", dev.name.UTF8String, i, got[i], kWant[i], seconds);
        return PASS(bug, "%s: a vertex function with %d chained checks built in %.1f s and draws right", dev.name.UTF8String, count, seconds);
    }
}
