// s57-intel-mps-matmul: MPSNDArray and MPSGraph matrix multiplication must compute; on Haswell / Ivy Bridge MPS encoded
// nothing (all 0). Fix: MetalOldCompat item 43 MTLSHIM_MPS_MATMUL.
// Checks: float32 products of several shapes (batched, B transposed), against the CPU. Argument: GPU name.
#import "repro.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

static NSData *values(NSUInteger n, uint32_t seed) {
    NSMutableData *d = [NSMutableData dataWithLength:n * 4];
    for (NSUInteger i = 0; i < n; i++) seed = seed * 1664525u + 1013904223u, ((float *)d.mutableBytes)[i] = (float)((seed >> 9) % 2001) / 1000.0f - 1.0f;
    return d;
}

// Largest error relative to the sum of |terms| of an element, over batch x M x N; B is K x N, or N x K when transposed.
static double worst(const float *a, const float *b, const float *c, NSUInteger batch, NSUInteger M, NSUInteger N, NSUInteger K, BOOL transB) {
    double w = 0;
    for (NSUInteger s = 0; s < batch; s++)
        for (NSUInteger i = 0; i < M; i++)
            for (NSUInteger j = 0; j < N; j++) {
                double want = 0, mag = 1e-6;
                for (NSUInteger k = 0; k < K; k++) {
                    double t = (double)a[(s * M + i) * K + k] * b[transB ? (s * N + j) * K + k : (s * K + k) * N + j];
                    want += t, mag += fabs(t);
                }
                w = fmax(w, fabs(c[(s * M + i) * N + j] - want) / mag);
            }
    return w;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s57-intel-mps-matmul";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        if (!MPSSupportsMTLDevice(dev)) return SKIP(bug, "%s: MPS doesn't support this GPU", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MPSGraphDevice *gd = [MPSGraphDevice deviceWithMTLDevice:dev];
        static const NSUInteger kCases[][5] = {{1, 16, 16, 16, 0}, {1, 37, 513, 101, 0}, {4, 32, 24, 40, 1}};  // batch, M, N, K, B transposed
        for (int c = 0; c < 3; c++) {
            NSUInteger batch = kCases[c][0], M = kCases[c][1], N = kCases[c][2], K = kCases[c][3];
            BOOL transB = kCases[c][4];
            NSArray<NSNumber *> *sa = batch > 1 ? @[@(batch), @(M), @(K)] : @[@(M), @(K)];
            NSArray<NSNumber *> *sb = transB ? (batch > 1 ? @[@(batch), @(N), @(K)] : @[@(N), @(K)]) : (batch > 1 ? @[@(batch), @(K), @(N)] : @[@(K), @(N)]);
            NSData *A = values(batch * M * K, 11 + c), *B = values(batch * K * N, 71 + c);
            MPSGraph *g = [MPSGraph new];
            MPSGraphTensor *ta = [g placeholderWithShape:sa dataType:MPSDataTypeFloat32 name:nil];
            MPSGraphTensor *tb = [g placeholderWithShape:sb dataType:MPSDataTypeFloat32 name:nil];
            MPSGraphTensor *rhs = transB ? [g transposeTensor:tb dimension:sb.count - 2 withDimension:sb.count - 1 name:nil] : tb;
            MPSGraphTensor *tc = [g matrixMultiplicationWithPrimaryTensor:ta secondaryTensor:rhs name:nil];
            NSDictionary *res = [g runWithMTLCommandQueue:q
                                                    feeds:@{ta : [[MPSGraphTensorData alloc] initWithDevice:gd data:A shape:sa dataType:MPSDataTypeFloat32],
                                                            tb : [[MPSGraphTensorData alloc] initWithDevice:gd data:B shape:sb dataType:MPSDataTypeFloat32]}
                                            targetTensors:@[tc] targetOperations:nil];
            NSMutableData *C = [NSMutableData dataWithLength:batch * M * N * 4];
            [[res[tc] mpsndarray] readBytes:C.mutableBytes strideBytes:nil];
            double e = worst(A.bytes, B.bytes, C.bytes, batch, M, N, K, transB);
            if (!(e < 1e-4))
                return FAIL(bug, "%s: MPSGraph matmul %lux%lux%lu%s%s: relative error %.2g (C[0] = %g)", dev.name.UTF8String, (unsigned long)M, (unsigned long)N,
                            (unsigned long)K, batch > 1 ? ", batch 4" : "", transB ? ", B transposed" : "", e, ((const float *)C.bytes)[0]);
        }
        // MPSNDArrayMatrixMultiplication directly, 48 x 40 x 56
        const NSUInteger M = 48, N = 40, K = 56;
        NSData *A = values(M * K, 5), *B = values(K * N, 6);
        MPSNDArray *na = [[MPSNDArray alloc] initWithDevice:dev descriptor:[MPSNDArrayDescriptor descriptorWithDataType:MPSDataTypeFloat32 shape:@[@(M), @(K)]]];
        MPSNDArray *nb = [[MPSNDArray alloc] initWithDevice:dev descriptor:[MPSNDArrayDescriptor descriptorWithDataType:MPSDataTypeFloat32 shape:@[@(K), @(N)]]];
        MPSNDArray *nc = [[MPSNDArray alloc] initWithDevice:dev descriptor:[MPSNDArrayDescriptor descriptorWithDataType:MPSDataTypeFloat32 shape:@[@(M), @(N)]]];
        [na writeBytes:(void *)A.bytes strideBytes:nil];
        [nb writeBytes:(void *)B.bytes strideBytes:nil];
        MPSNDArrayMatrixMultiplication *mm = [[MPSNDArrayMatrixMultiplication alloc] initWithDevice:dev sourceCount:2];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        [mm encodeToCommandBuffer:cb sourceArrays:@[na, nb] destinationArray:nc];
        [nc synchronizeOnCommandBuffer:cb];  // managed storage on a discrete GPU
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        NSMutableData *C = [NSMutableData dataWithLength:M * N * 4];
        [nc readBytes:C.mutableBytes strideBytes:nil];
        double e = worst(A.bytes, B.bytes, C.bytes, 1, M, N, K, NO);
        if (!(e < 1e-4))
            return FAIL(bug, "%s: MPSNDArrayMatrixMultiplication 48x40x56: relative error %.2g (C[0] = %g)", dev.name.UTF8String, e, ((const float *)C.bytes)[0]);
        return PASS(bug, "%s: MPSGraph and MPSNDArray matrix multiplication match the CPU (16x16x16, 37x513x101, batch 4 with B transposed, 48x40x56)",
                    dev.name.UTF8String);
    }
}
