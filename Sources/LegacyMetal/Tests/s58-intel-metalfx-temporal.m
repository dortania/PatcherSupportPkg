// s58-intel-metalfx-temporal (MetalOldCompat item 44): a GPU that MetalFX says supports its temporal scaler must get one
// that encodes. On the Haswell / Ivy Bridge GPUs, MTLFXTemporalScalerDescriptor said yes, but the temporal pass needs
// quad-group functions these GPUs don't have: its kernel failed to compile and the first encode crashed the app (a nil
// compute pipeline in the driver's setKernel). If supportsDevice: says yes, creates a 256 -> 512 temporal scaler and
// encodes a frame of a smooth image; if it says no, the scaler must not be created either.
// Stock OCLP: crash (no result line). Fixed: PASS (unsupported on the Intel GPU; working on the AMD GPU).
// Argument: GPU name substring (default: Intel).
#import "repro.h"
#import <MetalFX/MetalFX.h>

enum { IN = 256, OUT = 512 };

static id<MTLTexture> texture(id<MTLDevice> dev, MTLPixelFormat format, NSUInteger size, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:size height:size mipmapped:NO];
    d.usage = usage, d.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:d];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s58-intel-metalfx-temporal";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        BOOL supported = [MTLFXTemporalScalerDescriptor supportsDevice:dev];
        MTLFXTemporalScalerDescriptor *sd = [MTLFXTemporalScalerDescriptor new];
        sd.inputWidth = IN, sd.inputHeight = IN, sd.outputWidth = OUT, sd.outputHeight = OUT;
        sd.colorTextureFormat = sd.outputTextureFormat = MTLPixelFormatRGBA16Float;
        sd.depthTextureFormat = MTLPixelFormatDepth32Float, sd.motionTextureFormat = MTLPixelFormatRG16Float;
        id<MTLFXTemporalScaler> scaler = [sd newTemporalScalerWithDevice:dev];
        if (!supported)
            return scaler ? FAIL(bug, "%s: MetalFX says the temporal scaler is unsupported but made one", dev.name.UTF8String)
                          : PASS(bug, "%s: MetalFX reports its temporal scaler unsupported and doesn't make one", dev.name.UTF8String);
        if (!scaler) return FAIL(bug, "%s: MetalFX says the temporal scaler is supported but made none", dev.name.UTF8String);
        id<MTLTexture> color = texture(dev, MTLPixelFormatRGBA16Float, IN, scaler.colorTextureUsage);
        id<MTLTexture> depth = texture(dev, MTLPixelFormatDepth32Float, IN, scaler.depthTextureUsage);
        id<MTLTexture> motion = texture(dev, MTLPixelFormatRG16Float, IN, scaler.motionTextureUsage);
        id<MTLTexture> output = texture(dev, MTLPixelFormatRGBA16Float, OUT, scaler.outputTextureUsage);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> pixels = [dev newBufferWithLength:IN * IN * 8 options:MTLResourceStorageModeShared];
        __fp16 *p = pixels.contents;
        for (int i = 0; i < IN * IN; i++) {
            float x = (i % IN + 0.5f) / IN, y = (i / IN + 0.5f) / IN;
            p[i * 4] = (__fp16)x, p[i * 4 + 1] = (__fp16)y, p[i * 4 + 2] = (__fp16)(0.5f * (x + y)), p[i * 4 + 3] = 1;
        }
        id<MTLBuffer> zeros = [dev newBufferWithLength:IN * IN * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:pixels sourceOffset:0 sourceBytesPerRow:IN * 8 sourceBytesPerImage:IN * IN * 8 sourceSize:MTLSizeMake(IN, IN, 1)
                   toTexture:color destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit copyFromBuffer:zeros sourceOffset:0 sourceBytesPerRow:IN * 4 sourceBytesPerImage:IN * IN * 4 sourceSize:MTLSizeMake(IN, IN, 1)
                   toTexture:depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit copyFromBuffer:zeros sourceOffset:0 sourceBytesPerRow:IN * 4 sourceBytesPerImage:IN * IN * 4 sourceSize:MTLSizeMake(IN, IN, 1)
                   toTexture:motion destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        scaler.colorTexture = color, scaler.depthTexture = depth, scaler.motionTexture = motion, scaler.outputTexture = output;
        scaler.inputContentWidth = IN, scaler.inputContentHeight = IN, scaler.reset = YES;
        [scaler encodeToCommandBuffer:cb];
        id<MTLBuffer> back = [dev newBufferWithLength:OUT * OUT * 8 options:MTLResourceStorageModeShared];
        blit = [cb blitCommandEncoder];
        [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(OUT, OUT, 1) toBuffer:back
            destinationOffset:0 destinationBytesPerRow:OUT * 8 destinationBytesPerImage:OUT * OUT * 8];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const __fp16 *o = back.contents;
        double worst = 0;
        for (int i = 0; i < OUT * OUT; i++) {  // the red channel of a smooth ramp should come back near x
            float x = (i % OUT + 0.5f) / OUT, v = o[i * 4];
            worst = fmax(worst, isnan(v) ? 1 : fabs(v - x));
        }
        if (worst > 0.05) return FAIL(bug, "%s: the temporal scaler's output is off by up to %.3f on a ramp", dev.name.UTF8String, worst);
        return PASS(bug, "%s: MetalFX's temporal scaler is supported, builds and upscales a ramp (max error %.3f)", dev.name.UTF8String, worst);
    }
}
