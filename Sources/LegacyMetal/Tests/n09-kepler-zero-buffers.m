// n09-kepler-zero-buffers: new buffers must read 0; Kepler handed out freed private buffers, managed buffers' GPU
// copies and counter sample results as they were. Fix: MetalOldCompat item 60. Checks: 1 MB private and managed buffers
// and 4096-slot sample buffers, filled, freed and made again. Argument: GPU name (default: NVIDIA).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n09-kepler-zero-buffers";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const NSUInteger size = 1 << 20;
    const MTLResourceOptions modes[2] = {MTLResourceStorageModePrivate, MTLResourceStorageModeManaged};
    const char *const modeNames[2] = {"private", "managed"};
    for (int m = 0; m < 2; m++)
    for (int round = 0; round < 4; round++) {
        @autoreleasepool {
            id<MTLBuffer> dirty = [dev newBufferWithLength:size options:modes[m]];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be fillBuffer:dirty range:NSMakeRange(0, size) value:0xAB];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: fill failed", name);
        }
        id<MTLBuffer> fresh = [dev newBufferWithLength:size options:modes[m]];
        id<MTLBuffer> read = [dev newBufferWithLength:size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromBuffer:fresh sourceOffset:0 toBuffer:read destinationOffset:0 size:size];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: read-back failed", name);
        const uint8_t *p = read.contents;
        NSUInteger nonzero = 0;
        for (NSUInteger i = 0; i < size; i++) nonzero += p[i] != 0;
        if (nonzero) return FAIL(bug, "%s: a new 1 MB %s buffer has %lu non-zero bytes on the GPU (first %#x)", name, modeNames[m], (unsigned long)nonzero, p[0]);
    }
    id<MTLCounterSet> timestamps = nil;
    for (id<MTLCounterSet> set in dev.counterSets) if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
    if (timestamps && [dev supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary]) {
        MTLCounterSampleBufferDescriptor *sd = [MTLCounterSampleBufferDescriptor new];
        sd.counterSet = timestamps;
        sd.sampleCount = 4096;
        sd.storageMode = MTLStorageModePrivate;
        NSError *err = nil;
        for (int round = 0; round < 3; round++) {
            @autoreleasepool {
                id<MTLCounterSampleBuffer> used = [dev newCounterSampleBufferWithDescriptor:sd error:&err];
                if (!used) return FAIL(bug, "%s: sample buffer: %s", name, err.localizedDescription.UTF8String);
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                for (NSUInteger i = 0; i < sd.sampleCount; i++) [be sampleCountersInBuffer:used atSampleIndex:i withBarrier:YES];
                [be endEncoding];
                if (!reproRun(cb)) return FAIL(bug, "%s: sampling failed", name);
            }
            id<MTLCounterSampleBuffer> fresh = [dev newCounterSampleBufferWithDescriptor:sd error:&err];
            id<MTLBuffer> out = [dev newBufferWithLength:sd.sampleCount * 8 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be resolveCounters:fresh inRange:NSMakeRange(0, sd.sampleCount) destinationBuffer:out destinationOffset:0];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: resolve failed", name);
            const uint64_t *v = out.contents;
            NSUInteger nonzero = 0;
            for (NSUInteger i = 0; i < sd.sampleCount; i++) nonzero += v[i] != 0;
            if (nonzero) return FAIL(bug, "%s: a new sample buffer resolves %lu of %lu unsampled slots non-zero (slot 0: %llu)", name,
                                     (unsigned long)nonzero, (unsigned long)sd.sampleCount, (unsigned long long)v[0]);
        }
    }
    return PASS(bug, "%s: new private and managed buffers and new sample buffers' slots read 0", name);
}}
