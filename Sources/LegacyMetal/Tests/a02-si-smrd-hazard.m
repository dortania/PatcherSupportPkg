// a02-si-smrd-hazard (AMD adapter, GCN1/SI only): the 12.5 shader compiler (SC) builds a buffer descriptor with scalar
// ALU instructions and reads through it with s_buffer_load right away; SI needs 4 wait states between them (LLVM:
// GCNHazardRecognizer::checkSMRDHazards). Without them the load sees the stale descriptor, is out of range and returns
// 0. Metal argument buffers produce exactly this for every pointer they hold, and ANGLE puts every WebGL uniform block
// in one: deqp uniformbuffers/random basic_types.19, basic_arrays.2, nested_structs.10 fail on every run in Chrome
// and Safari. This program replays ANGLE's translated shaders of basic_types.19 (data/ubo19-*.metal): each stage
// writes 1 if every uniform it read matched, so a correct render is white.
// Stock OCLP (SI GPU): FAIL (blue = 0: the fragment shader read zeros). Fixed: PASS. Argument: GPU (default: AMD).
#import "repro.h"

static NSString *dataDir(char **argv) {
    return [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
}

static id<MTLFunction> mainOf(id<MTLDevice> dev, NSString *path, NSString **problem) {
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!src) { *problem = [@"missing " stringByAppendingString:path]; return nil; }
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:o error:&e];
    if (!lib) { *problem = e.localizedDescription; return nil; }
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    bool no = false;
    for (NSUInteger i = 0; i < 6; i++) [cv setConstantValue:&no type:MTLDataTypeBool atIndex:i];
    id<MTLFunction> f = [lib newFunctionWithName:@"main0" constantValues:cv error:&e];
    if (!f) *problem = e.localizedDescription;
    return f;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a02-si-smrd-hazard";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *dir = dataDir(argv), *problem = nil;
        id<MTLFunction> vs = mainOf(dev, [dir stringByAppendingPathComponent:@"ubo19-vs.metal"], &problem);
        id<MTLFunction> fs = vs ? mainOf(dev, [dir stringByAppendingPathComponent:@"ubo19-fs.metal"], &problem) : nil;
        if (!vs || !fs) return problem && [problem hasPrefix:@"missing"] ? SKIP(bug, "%s", problem.UTF8String) : FAIL(bug, "%s", problem.UTF8String);
        NSError *e = nil;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSMutableArray<id<MTLBuffer>> *blocks = [NSMutableArray array];
        for (int i = 0; i < 8; i++) {
            [blocks addObject:[dev newBufferWithLength:512 options:MTLResourceStorageModeShared]];
            memset(blocks[i].contents, 0xb0 + i, 512);
        }
        NSString *blockSrc = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"ubo19.metal"] encoding:NSUTF8StringEncoding error:nil];
        id<MTLLibrary> blockLib = [dev newLibraryWithSource:blockSrc options:nil error:&e];
        id<MTLComputePipelineState> fill = [dev newComputePipelineStateWithFunction:[blockLib newFunctionWithName:@"fill"] error:&e];
        if (!fill) return FAIL(bug, "fill kernel: %s", e.localizedDescription.UTF8String);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:fill];
        for (int i = 0; i < 8; i++) [ce setBuffer:blocks[i] offset:0 atIndex:1 + i];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        // ANGLE's uniform blocks: argument buffers at buffer(24); vertex ids 0,1,2 -> blocks 0,1,2, fragment 0,3,4.
        id<MTLArgumentEncoder> venc = [vs newArgumentEncoderWithBufferIndex:24], fenc = [fs newArgumentEncoderWithBufferIndex:24];
        if (!venc || !fenc) return FAIL(bug, "no argument encoder (see s14 if this process path contains \"Safari\")");
        id<MTLBuffer> vargs = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        id<MTLBuffer> fargs = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        [venc setArgumentBuffer:vargs offset:0];
        [fenc setArgumentBuffer:fargs offset:0];
        const int vsIds[] = {0, 1, 2}, fsIds[] = {0, 3, 4};
        for (int i = 0; i < 3; i++) { [venc setBuffer:blocks[vsIds[i]] offset:0 atIndex:i]; [fenc setBuffer:blocks[fsIds[i]] offset:0 atIndex:i]; }
        // ANGLE driver uniforms (buffer 17): depth range 0..1, render area 4x4, no flips.
        struct { float depthRange[2]; uint32_t renderArea, flipXY, misc; int baseInstance; uint32_t acb[2]; int xfb[4];
                 int xfbVerts; uint32_t coverageMask, unused[2]; } uniforms = {{0, 1}, 4 | 4 << 16, 0x7f7f7f7f, 0, 0, {0}, {0}, 0, ~0u, {0}};
        float quad[16] = {-1, -1, 0, 1, 1, -1, 0, 1, -1, 1, 0, 1, 1, 1, 0, 1};
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vs; pd.fragmentFunction = fs;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].bufferIndex = 0; vd.layouts[0].stride = 16;
        pd.vertexDescriptor = vd;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!ps) return FAIL(bug, "pipeline: %s", e.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re setVertexBytes:quad length:sizeof quad atIndex:0];
        [re setVertexBuffer:vargs offset:0 atIndex:24]; [re setFragmentBuffer:fargs offset:0 atIndex:24];
        [re setVertexBytes:&uniforms length:sizeof uniforms atIndex:17]; [re setFragmentBytes:&uniforms length:sizeof uniforms atIndex:17];
        for (id<MTLBuffer> b in blocks) [re useResource:b usage:MTLResourceUsageRead stages:MTLRenderStageVertex | MTLRenderStageFragment];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:target];
        [be endEncoding];
        reproRun(cb);
        uint8_t px[4];
        [target getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        if (px[0] != 255 || px[1] != 255 || px[2] != 255 || px[3] != 255)
            return FAIL(bug, "%s: deqp ubo.random.basic_types.19 replay: color %d %d %d %d (want 255 255 255 255; G = vertex, B = fragment uniforms)",
                        dev.name.UTF8String, px[0], px[1], px[2], px[3]);
        return PASS(bug, "%s: deqp ubo.random.basic_types.19 replay: every uniform read correctly", dev.name.UTF8String);
    }
}
