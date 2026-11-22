// s78-mps-kernels (sweep): Metal Performance Shaders kernels that Vision, Core ML, Photos and apps reach, run on the GPU
// under test and checked against values computed here: image kernels (3x3 convolution with bias, box, area max/min,
// dilate/erode, binary threshold, transpose, median, integral, Gaussian blur), a CNN neuron (leaky ReLU), matrix kernels
// (matrix x vector, row softmax) and an MPSGraph (matmul, ReLU, row sum). Neighbourhood kernels are compared away from
// the edges (edge modes differ by kernel); the Gaussian only loosely (MPS picks its own kernel size for a sigma).
// Argument: GPU name substring (default: Intel).
#import "repro.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#include <math.h>

enum { N = 32 };
static float src[N * N];
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;

static float hash(int x, int y) { float v = sinf(x * 12.9898f + y * 78.233f) * 43758.5453f; return v - floorf(v); }
static float at(int x, int y) { x = x < 0 ? 0 : x >= N ? N - 1 : x; y = y < 0 ? 0 : y >= N ? N - 1 : y; return src[y * N + x]; }

static id<MTLTexture> texture(int w, int h, const float *data) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; d.storageMode = MTLStorageModeManaged;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    if (data) [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data bytesPerRow:w * 4];
    return t;
}
static void readBack(id<MTLCommandBuffer> cb, id<MTLTexture> t, float *out) {
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b synchronizeResource:t]; [b endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    [t getBytes:out bytesPerRow:t.width * 4 fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
}

static NSMutableArray *bad;
static int checks;
// compare out with expected(x, y) over [m, w-m) x [m, h-m)
static void compare(const char *name, const float *out, int w, int h, int m, float tol, float (^expected)(int x, int y)) {
    float worst = 0; int wx = 0, wy = 0;
    for (int y = m; y < h - m; y++) for (int x = m; x < w - m; x++) {
        float d = fabsf(out[y * w + x] - expected(x, y));
        if (!(d <= worst)) { worst = d; wx = x; wy = y; }
    }
    checks++;
    if (!(worst <= tol)) [bad addObject:[NSString stringWithFormat:@"%s: (%d, %d) is %.5f, want %.5f", name, wx, wy, out[wy * w + wx], expected(wx, wy)]];
}

static void imageKernel(const char *name, MPSUnaryImageKernel *k, int dw, int dh, int margin, float tol, float (^expected)(int, int)) {
    id<MTLTexture> s = texture(N, N, src), d = texture(dw, dh, NULL);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    [k encodeToCommandBuffer:cb sourceTexture:s destinationTexture:d];
    static float out[N * N]; memset(out, 0, sizeof out);
    readBack(cb, d, out);
    compare(name, out, dw, dh, margin, tol, expected);
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s78-mps-kernels";
    dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    if (!MPSSupportsMTLDevice(dev)) return SKIP(bug, "%s: MPS doesn't support this GPU", dev.name.UTF8String);
    queue = [dev newCommandQueue]; bad = [NSMutableArray array];
    for (int y = 0; y < N; y++) for (int x = 0; x < N; x++) src[y * N + x] = hash(x, y);

    // 3x3 convolution (symmetric weights, so correlation and convolution agree) + bias
    static const float w[9] = {1, 2, 1, 2, 4, 2, 1, 2, 1};
    static float wn[9]; for (int i = 0; i < 9; i++) wn[i] = w[i] / 16.0f;
    MPSImageConvolution *conv = [[MPSImageConvolution alloc] initWithDevice:dev kernelWidth:3 kernelHeight:3 weights:wn];
    conv.bias = 0.125f;
    imageKernel("convolution 3x3 + bias", conv, N, N, 2, 1e-4f, ^float(int x, int y) {
        float s = 0.125f; for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) s += wn[(j + 1) * 3 + i + 1] * at(x + i, y + j); return s; });
    imageKernel("box 3x3", [[MPSImageBox alloc] initWithDevice:dev kernelWidth:3 kernelHeight:3], N, N, 2, 1e-4f, ^float(int x, int y) {
        float s = 0; for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) s += at(x + i, y + j); return s / 9; });
    float (^nmax)(int, int) = ^float(int x, int y) { float s = -1; for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) s = fmaxf(s, at(x + i, y + j)); return s; };
    float (^nmin)(int, int) = ^float(int x, int y) { float s = 2; for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) s = fminf(s, at(x + i, y + j)); return s; };
    imageKernel("area max 3x3", [[MPSImageAreaMax alloc] initWithDevice:dev kernelWidth:3 kernelHeight:3], N, N, 2, 1e-6f, nmax);
    imageKernel("area min 3x3", [[MPSImageAreaMin alloc] initWithDevice:dev kernelWidth:3 kernelHeight:3], N, N, 2, 1e-6f, nmin);
    static const float flat[9] = {0};
    imageKernel("dilate 3x3", [[MPSImageDilate alloc] initWithDevice:dev kernelWidth:3 kernelHeight:3 values:flat], N, N, 2, 1e-6f, nmax);
    imageKernel("erode 3x3", [[MPSImageErode alloc] initWithDevice:dev kernelWidth:3 kernelHeight:3 values:flat], N, N, 2, 1e-6f, nmin);
    imageKernel("threshold binary", [[MPSImageThresholdBinary alloc] initWithDevice:dev thresholdValue:0.5f maximumValue:0.75f linearGrayColorTransform:nil],
                N, N, 0, 1e-6f, ^float(int x, int y) { return at(x, y) > 0.5f ? 0.75f : 0.0f; });
    imageKernel("transpose", [[MPSImageTranspose alloc] initWithDevice:dev], N, N, 0, 0, ^float(int x, int y) { return at(y, x); });
    imageKernel("median 3x3", [[MPSImageMedian alloc] initWithDevice:dev kernelDiameter:3], N, N, 2, 1e-6f, ^float(int x, int y) {
        float v[9]; int n = 0; for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) v[n++] = at(x + i, y + j);
        for (int a = 0; a < 9; a++) { for (int b = a + 1; b < 9; b++) { if (v[b] < v[a]) { float t = v[a]; v[a] = v[b]; v[b] = t; } } }
        return v[4]; });
    imageKernel("integral", [[MPSImageIntegral alloc] initWithDevice:dev], N, N, 0, 2e-3f, ^float(int x, int y) {
        double s = 0; for (int j = 0; j <= y; j++) for (int i = 0; i <= x; i++) s += at(i, j); return (float)s; });
    imageKernel("gaussian blur sigma 1.5", [[MPSImageGaussianBlur alloc] initWithDevice:dev sigma:1.5f], N, N, 6, 0.02f, ^float(int x, int y) {
        double s = 0, ws = 0;
        for (int j = -5; j <= 5; j++) for (int i = -5; i <= 5; i++) { double g = exp(-(i * i + j * j) / (2 * 1.5 * 1.5)); s += g * at(x + i, y + j); ws += g; }
        return (float)(s / ws); });

    // CNN neuron: leaky ReLU (a = 0.1) on values in [-0.5, 0.5)
    {
        static float in[N * N]; for (int i = 0; i < N * N; i++) in[i] = src[i] - 0.5f;
        MPSImage *si = [[MPSImage alloc] initWithTexture:texture(N, N, in) featureChannels:1];
        MPSImage *di = [[MPSImage alloc] initWithTexture:texture(N, N, NULL) featureChannels:1];
        MPSCNNNeuron *relu = [[MPSCNNNeuron alloc] initWithDevice:dev neuronDescriptor:
                              [MPSNNNeuronDescriptor cnnNeuronDescriptorWithType:MPSCNNNeuronTypeReLU a:0.1f]];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        [relu encodeToCommandBuffer:cb sourceImage:si destinationImage:di];
        static float out[N * N]; readBack(cb, di.texture, out);
        compare("CNN leaky ReLU", out, N, N, 0, 1e-6f, ^float(int x, int y) { float v = in[y * N + x]; return v >= 0 ? v : 0.1f * v; });
    }

    // matrix x vector and row softmax, 16 x 16
    {
        enum { M = 16 };
        id<MTLBuffer> A = [dev newBufferWithLength:M * M * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> X = [dev newBufferWithLength:M * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> Y = [dev newBufferWithLength:M * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> S = [dev newBufferWithLength:M * M * 4 options:MTLResourceStorageModeShared];
        float *a = A.contents, *x = X.contents;
        for (int i = 0; i < M * M; i++) a[i] = src[i] * 4 - 2;
        for (int i = 0; i < M; i++) x[i] = src[600 + i] - 0.5f;
        MPSMatrixDescriptor *md = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:M rowBytes:M * 4 dataType:MPSDataTypeFloat32];
        MPSVectorDescriptor *vd = [MPSVectorDescriptor vectorDescriptorWithLength:M dataType:MPSDataTypeFloat32];
        MPSMatrix *ma = [[MPSMatrix alloc] initWithBuffer:A descriptor:md], *ms = [[MPSMatrix alloc] initWithBuffer:S descriptor:md];
        MPSVector *vx = [[MPSVector alloc] initWithBuffer:X descriptor:vd], *vy = [[MPSVector alloc] initWithBuffer:Y descriptor:vd];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        [[[MPSMatrixVectorMultiplication alloc] initWithDevice:dev transpose:NO rows:M columns:M alpha:1 beta:0]
            encodeToCommandBuffer:cb inputMatrix:ma inputVector:vx resultVector:vy];
        [[[MPSMatrixSoftMax alloc] initWithDevice:dev] encodeToCommandBuffer:cb inputMatrix:ma resultMatrix:ms];
        [cb commit]; [cb waitUntilCompleted];
        const float *y = Y.contents, *s = S.contents;
        compare("matrix x vector", y, M, 1, 0, 1e-4f, ^float(int r, int unused) { double t = 0; for (int c = 0; c < M; c++) t += a[r * M + c] * x[c]; return (float)t; });
        compare("matrix row softmax", s, M, M, 0, 1e-5f, ^float(int c, int r) {
            double mx = -1e9, t = 0; for (int k = 0; k < M; k++) mx = fmax(mx, a[r * M + k]);
            for (int k = 0; k < M; k++) t += exp(a[r * M + k] - mx); return (float)(exp(a[r * M + c] - mx) / t); });
    }

    // MPSGraph: rowsum(relu(A x B)), 8 x 8
    {
        enum { K = 8 };
        static float ga[K * K], gb[K * K], gs[K];
        for (int i = 0; i < K * K; i++) { ga[i] = src[i + 100] - 0.5f; gb[i] = src[i + 300] - 0.5f; }
        MPSGraph *g = [MPSGraph new];
        MPSGraphTensor *ta = [g placeholderWithShape:@[@(K), @(K)] dataType:MPSDataTypeFloat32 name:nil];
        MPSGraphTensor *tb = [g placeholderWithShape:@[@(K), @(K)] dataType:MPSDataTypeFloat32 name:nil];
        MPSGraphTensor *sum = [g reductionSumWithTensor:[g reLUWithTensor:[g matrixMultiplicationWithPrimaryTensor:ta secondaryTensor:tb name:nil] name:nil] axis:1 name:nil];
        MPSGraphDevice *gd = [MPSGraphDevice deviceWithMTLDevice:dev];
        MPSGraphTensorData *da = [[MPSGraphTensorData alloc] initWithDevice:gd data:[NSData dataWithBytes:ga length:sizeof ga] shape:@[@(K), @(K)] dataType:MPSDataTypeFloat32];
        MPSGraphTensorData *db = [[MPSGraphTensorData alloc] initWithDevice:gd data:[NSData dataWithBytes:gb length:sizeof gb] shape:@[@(K), @(K)] dataType:MPSDataTypeFloat32];
        NSDictionary *res = nil;
        @try { res = [g runWithMTLCommandQueue:queue feeds:@{ta: da, tb: db} targetTensors:@[sum] targetOperations:nil]; } @catch (NSException *e) { res = nil; }
        if (!res[sum]) { checks++; [bad addObject:@"MPSGraph matmul + ReLU + row sum: no result"]; }
        else {
            [[res[sum] mpsndarray] readBytes:gs strideBytes:nil];
            compare("MPSGraph matmul + ReLU + row sum", gs, K, 1, 0, 1e-4f, ^float(int r, int unused) {
                double t = 0; for (int c = 0; c < K; c++) { double v = 0; for (int k = 0; k < K; k++) v += ga[r * K + k] * gb[k * K + c]; t += v > 0 ? v : 0; } return (float)t; });
        }
    }

    if (bad.count) {
        printf("  %s\n", [[bad componentsJoinedByString:@"\n  "] UTF8String]);
        return FAIL(bug, "%s: %lu of %d MPS kernels give wrong results", dev.name.UTF8String, (unsigned long)bad.count, checks);
    }
    return PASS(bug, "%s: %d MPS image, CNN, matrix and graph kernels compute right", dev.name.UTF8String, checks);
}}
