// n09-kepler-zero-buffers (MetalOldCompat item 60): new buffers must be zero-filled (newBufferWithLength:options: "creates
// a buffer that the method clears with zero values"). Kepler's driver (GeForceMTLDriver) hands a freed PRIVATE buffer's
// memory, as it was, to the next private buffer of the same size, and does the same with a counter sample buffer's own
// result buffer: unsampled timestamp slots of a new sample buffer resolved to a freed one's timestamps. Dawn relies on the
// zero fill: the WebGPU CTS read old values from unused query slots (timestampQuery unused_slots_are_zero), and a WebGPU
// buffer could show data another part of the page had freed. Fills and frees 1 MB private buffers (0xAB) and 4096-slot
// sample buffers (every slot sampled), then checks fresh ones read 0.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n09-kepler-zero-buffers";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const NSUInteger size = 1 << 20;
    for (int round = 0; round < 4; round++) {
        @autoreleasepool {
            id<MTLBuffer> dirty = [dev newBufferWithLength:size options:MTLResourceStorageModePrivate];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be fillBuffer:dirty range:NSMakeRange(0, size) value:0xAB];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: fill failed", name);
        }
        id<MTLBuffer> fresh = [dev newBufferWithLength:size options:MTLResourceStorageModePrivate];
        id<MTLBuffer> read = [dev newBufferWithLength:size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromBuffer:fresh sourceOffset:0 toBuffer:read destinationOffset:0 size:size];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: read-back failed", name);
        const uint8_t *p = read.contents;
        NSUInteger nonzero = 0;
        for (NSUInteger i = 0; i < size; i++) nonzero += p[i] != 0;
        if (nonzero) return FAIL(bug, "%s: a new 1 MB private buffer has %lu non-zero bytes (first %#x)", name, (unsigned long)nonzero, p[0]);
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
    return PASS(bug, "%s: new private buffers and new sample buffers' slots read 0", name);
}}
