// i71-intel-outer-axis-reduction (Intel adapter, IntelTextureAtomics.dylib): MPSGraph's reductions along an outer axis
// must compile and be right. MPS's reduce_multiple_passes_axes_* kernels, specialized for them, keep loops that never
// exit (where a stride of 0 would spin); nested in these kernels, the IGIL back end never finishes compiling them
// (USC::CompileComputeShaderOpenCL_Gen7 spins at 100%), so reductionMaximum or softMax over axis 0 of a 2D tensor waited
// forever, the stock compiler too. Runs both on the Intel GPU on another thread and waits up to 120 seconds, then checks
// them against the CPU (the compiler service of a timed-out run stops when this process exits).
// Stock OCLP on Tahoe: FAIL (timeout). Fixed: PASS. On Sequoia, whose MPSGraph builds these kernels differently: PASS
// either way. Argument: GPU name substring (default: Intel).
#import "repro.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

enum { R = 333, C = 64, SR = 100, SC = 16 };

static NSData *values(NSUInteger n, uint32_t seed) {
    NSMutableData *d = [NSMutableData dataWithLength:n * 4];
    for (NSUInteger i = 0; i < n; i++) seed = seed * 1664525u + 1013904223u, ((float *)d.mutableBytes)[i] = (float)((seed >> 9) % 2001) / 1000.0f - 1.0f;
    return d;
}

static NSData *run(id<MTLCommandQueue> q, MPSGraphDevice *gd, NSData *input, NSArray<NSNumber *> *shape, BOOL softmax) {
    MPSGraph *g = [MPSGraph new];
    MPSGraphTensor *x = [g placeholderWithShape:shape dataType:MPSDataTypeFloat32 name:nil];
    MPSGraphTensor *y = softmax ? [g softMaxWithTensor:x axis:0 name:nil] : [g reductionMaximumWithTensor:x axis:0 name:nil];
    NSDictionary *res = [g runWithMTLCommandQueue:q feeds:@{x : [[MPSGraphTensorData alloc] initWithDevice:gd data:input shape:shape dataType:MPSDataTypeFloat32]}
                                    targetTensors:@[y] targetOperations:nil];
    NSUInteger n = 1;
    for (NSNumber *s in [res[y] shape]) n *= s.unsignedIntegerValue;
    NSMutableData *out = [NSMutableData dataWithLength:n * 4];
    [[res[y] mpsndarray] readBytes:out.mutableBytes strideBytes:nil];
    return out;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i71-intel-outer-axis-reduction";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        if (!MPSSupportsMTLDevice(dev)) return SKIP(bug, "%s: MPS doesn't support this GPU", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MPSGraphDevice *gd = [MPSGraphDevice deviceWithMTLDevice:dev];
        NSData *a = values(R * C, 3), *b = values(SR * SC, 4);
        __block NSData *maxima = nil, *softmax = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            maxima = run(q, gd, a, @[@(R), @(C)], NO);
            softmax = run(q, gd, b, @[@(SR), @(SC)], YES);
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
            FAIL(bug, "%s: MPSGraph %s over axis 0 didn't finish in 120 s (the compiler service spins on its kernel)", dev.name.UTF8String,
                 maxima ? "softMax" : "reductionMaximum");
            fflush(stdout);
            _exit(1);
        }
        const float *x = a.bytes, *m = maxima.bytes;
        for (int c = 0; c < C; c++) {
            float want = -INFINITY;
            for (int r = 0; r < R; r++) want = fmaxf(want, x[r * C + c]);
            if (m[c] != want) return FAIL(bug, "%s: reductionMaximum over axis 0, column %d: %g, want %g", dev.name.UTF8String, c, m[c], want);
        }
        const float *y = b.bytes, *s = softmax.bytes;
        for (int c = 0; c < SC; c++) {
            double top = -INFINITY, sum = 0;
            for (int r = 0; r < SR; r++) top = fmax(top, y[r * SC + c]);
            for (int r = 0; r < SR; r++) sum += exp(y[r * SC + c] - top);
            for (int r = 0; r < SR; r++) {
                double want = exp(y[r * SC + c] - top) / sum;
                if (fabs(s[r * SC + c] - want) > 1e-5 + 1e-4 * want)
                    return FAIL(bug, "%s: softMax over axis 0, [%d][%d]: %g, want %g", dev.name.UTF8String, r, c, s[r * SC + c], want);
            }
        }
        return PASS(bug, "%s: MPSGraph reductionMaximum (333x64) and softMax (100x16) over axis 0 compile and are right", dev.name.UTF8String);
    }
}
