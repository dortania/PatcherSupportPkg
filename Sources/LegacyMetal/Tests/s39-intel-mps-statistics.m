// s39-intel-mps-statistics (MetalOldCompat item 35): Metal Performance Shaders' image statistics end with a
// compute_final_*_statistics kernel that assumes at least 32 threads per threadgroup; MPS dispatches it with the pipeline's
// threadExecutionWidth, 16 on these Intel GPUs, and its first reduction step reads past the threadgroup memory as 0.
// MPSImageStatisticsMinAndMax returned 0 minimums (and 0 maximums for negative data), MeanAndVariance wrong means and
// variances; Core Image's CIAreaMinMax, which runs on it, too. Both kernels run on a 37x23 RGBA32Float texture with
// positive and negative channels and are checked against the values computed here. Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: Intel). SKIP where Metal Performance Shaders doesn't support the GPU.
#import "repro.h"
#include <dlfcn.h>
#include <math.h>
#include <objc/message.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s39-intel-mps-statistics";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        if (!dlopen("/System/Library/Frameworks/MetalPerformanceShaders.framework/MetalPerformanceShaders", RTLD_NOW))
            return SKIP(bug, "no MetalPerformanceShaders");
        BOOL (*supports)(id<MTLDevice>) = (BOOL (*)(id<MTLDevice>))dlsym(RTLD_DEFAULT, "MPSSupportsMTLDevice");
        if (!supports || !supports(dev)) return SKIP(bug, "%s: Metal Performance Shaders doesn't support this GPU", dev.name.UTF8String);
        const int W = 37, H = 23;
        float *texels = calloc(W * H * 4, sizeof(float));
        double sum[4] = {0}, squares[4] = {0}, low[4], high[4];
        for (int c = 0; c < 4; c++) low[c] = INFINITY, high[c] = -INFINITY;
        for (int i = 0; i < W * H; i++)
            for (int c = 0; c < 4; c++) {
                float x = c == 3 ? 1 : c == 1 ? -0.3f - 0.01f * (i % 17) : 0.2f + 0.013f * ((i * 7 + c) % 31);
                texels[4 * i + c] = x;
                sum[c] += x, squares[c] += (double)x * x, low[c] = fmin(low[c], x), high[c] = fmax(high[c], x);
            }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> source = [dev newTextureWithDescriptor:td];
        [source replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:texels bytesPerRow:W * 16];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const char *kKernels[2] = {"MPSImageStatisticsMinAndMax", "MPSImageStatisticsMeanAndVariance"};
        for (int k = 0; k < 2; k++) {
            Class cls = NSClassFromString(@(kKernels[k]));
            if (!cls) return SKIP(bug, "no %s", kKernels[k]);
            id kernel = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], @selector(initWithDevice:), dev);
            MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:1 mipmapped:NO];
            od.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            od.storageMode = MTLStorageModeManaged;
            id<MTLTexture> result = [dev newTextureWithDescriptor:od];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(kernel, @selector(encodeToCommandBuffer:sourceTexture:destinationTexture:), cb, source, result);
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:result];
            [blit endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            float got[8];
            [result getBytes:got bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0];
            for (int c = 0; c < 4; c++) {
                double mean = sum[c] / (W * H), want[2];
                if (k == 0) want[0] = low[c], want[1] = high[c];
                else want[0] = mean, want[1] = squares[c] / (W * H) - mean * mean;
                for (int j = 0; j < 2; j++)
                    if (fabs(got[4 * j + c] - want[j]) > 1e-3)
                        return FAIL(bug, "%s: %s channel %d: %s %g, want %g", dev.name.UTF8String, kKernels[k], c,
                                    k == 0 ? (j ? "maximum" : "minimum") : (j ? "variance" : "mean"), got[4 * j + c], want[j]);
            }
        }
        free(texels);
        return PASS(bug, "%s: MPS minimum/maximum and mean/variance right", dev.name.UTF8String);
    }
}
