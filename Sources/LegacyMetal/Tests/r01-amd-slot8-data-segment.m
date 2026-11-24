// r01-amd-slot8-data-segment: guards a04's fix; must keep working, with or without it: program-scope constants (slot 8)
// in fragment shaders and threadgroup kernels. Fix: AMDTextureAtomics AMD_LDS_BASE_FIX.
// Checks: a fragment shader reading a volatile constant; a threadgroup reduction reading one. Argument: GPU name.
#import "repro.h"

static NSString *const common = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "volatile constexpr constant uint kMagic = 0x2468ACE1u;\n";
static NSString *const fragmentSrc = @"struct VO { float4 p [[position]]; };\n"
    "vertex VO vs(uint v [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VO o; o.p = float4(p[v], 0, 1); return o; }\n"
    "fragment uint4 fs(VO in [[stage_in]]) { return uint4(kMagic, kMagic >> 8, 7u, 9u); }\n";
static NSString *const computeSrc = @"class Impl {\n"
    "public:\n"
    "  threadgroup float (&array_of_values)[256];\n"
    "  uint tid; float scratch_values[16];\n"
    "  Impl(threadgroup float (&a)[256]) : array_of_values(a) {}\n"
    "  float parallelMax(float value) {\n"
    "    array_of_values[tid] = value;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    for (uint i = 256; i > 0; i >>= 1) { uint h = i >> 1; if (tid < h) array_of_values[tid] = max(array_of_values[tid], array_of_values[tid + h]);\n"
    "      threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    return array_of_values[0]; }\n"
    "};\n"
    "kernel void k(device uint2 *out [[buffer(0)]], constant uint &sel [[buffer(1)]], uint tid [[thread_index_in_threadgroup]],\n"
    "              uint gid [[thread_position_in_grid]], uint group [[threadgroup_position_in_grid]]) {\n"
    "  threadgroup float array_of_values[256];\n"
    "  Impl impls[2] = {Impl(array_of_values), Impl(array_of_values)};\n"
    "  thread Impl &impl = impls[sel & 1u];\n"
    "  impl.tid = tid;\n"
    "  for (int i = 0; i < 16; i++) impl.scratch_values[i] = float(gid + i);\n"
    "  float m = impl.parallelMax(float((tid * 37u) % 256u) + float(group) * 1000.0f + impl.scratch_values[sel & 15u] * 0.0f);\n"
    "  out[gid] = uint2(uint(m), kMagic);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "r01-amd-slot8-data-segment";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        char problems[512] = "";
        // 1. fragment shader: the constant read through the data segment
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:[common stringByAppendingString:fragmentSrc]] options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> rps = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        if (!rps) return FAIL(bug, "render pipeline: %s", err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:rps]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be synchronizeResource:rt]; [be endEncoding];
        reproRun(cb);
        uint32_t px[4];
        [rt getBytes:px bytesPerRow:64 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        if (px[0] != 0x2468ACE1u || px[1] != 0x2468ACE1u >> 8 || px[2] != 7 || px[3] != 9)
            snprintf(problems, sizeof problems, "fragment shader read constant %#x, want 0x2468ace1", px[0]);
        // 2. compute kernel: threadgroup reduction through a reference member + the constant
        lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:[common stringByAppendingString:computeSrc]] options:nil error:&err];
        id<MTLComputePipelineState> cps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err] : nil;
        if (!cps) return FAIL(bug, "compute pipeline: %s", err.localizedDescription.UTF8String);
        if (cps.maxTotalThreadsPerThreadgroup < 256) return SKIP(bug, "compute pipeline allows only %lu threads", (unsigned long)cps.maxTotalThreadsPerThreadgroup);
        const uint32_t groups = 8, N = groups * 256, sel = 3;
        id<MTLBuffer> out = [dev newBufferWithLength:N * 8 options:MTLResourceStorageModeShared];
        cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cps]; [ce setBuffer:out offset:0 atIndex:0]; [ce setBytes:&sel length:4 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [ce endEncoding];
        reproRun(cb);
        const uint32_t *o = out.contents;
        uint32_t badMax = 0, badConst = 0;
        for (uint32_t i = 0; i < N; i++) {
            badMax += o[i * 2] != 255 + (i / 256) * 1000;
            badConst += o[i * 2 + 1] != 0x2468ACE1u;
        }
        if (badMax || badConst)
            snprintf(problems + strlen(problems), sizeof problems - strlen(problems), "%scompute kernel: threadgroup max wrong in %u of %u threads, constant wrong in %u (e.g. %#x)",
                     *problems ? "; " : "", badMax, N, badConst, o[1]);
        if (*problems) return FAIL(bug, "%s: %s", dev.name.UTF8String, problems);
        return PASS(bug, "%s: program-scope constant read correctly in a fragment shader and in a compute kernel with a threadgroup reduction", dev.name.UTF8String);
    }
}
