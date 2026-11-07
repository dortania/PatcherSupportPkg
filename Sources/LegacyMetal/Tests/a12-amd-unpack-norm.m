// a12-amd-unpack-norm (AMD adapter, AMDTextureAtomics.dylib): unpack_snorm2x16_to_float, unpack_unorm2x16_to_float,
// unpack_snorm4x8_to_float and unpack_unorm4x8_to_float with the 12.5 AMD compiler. libAMDIL902 gets the 2x16 forms up to
// 6 (snorm) and 2 (unorm) ulp wrong in every shader stage; GLSL ES 3.0 allows 1, and WebGL 2 checks it (dEQP
// shaderpackingfunction unpacksnorm2x16 / unpackunorm2x16). Every 16-bit value (for the 4x8 forms, every byte in every
// position) goes through a compute kernel and a fragment function, against the exact quotient, clamped to -1 for snorm.
// Stock OCLP: FAIL. Fixed: PASS (within 1 ulp everywhere).
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "static float4 unpack(uint v, uint form) {\n"
    "    switch (form) {\n"
    "    case 0: return float4(unpack_snorm2x16_to_float(v), 0, 0);\n"
    "    case 1: return float4(unpack_unorm2x16_to_float(v), 0, 0);\n"
    "    case 2: return unpack_snorm4x8_to_float(v);\n"
    "    default: return unpack_unorm4x8_to_float(v);\n"
    "    }\n"
    "}\n"
    "kernel void ck(device const uint *in [[buffer(0)]], device float4 *out [[buffer(1)]], constant uint &form [[buffer(2)]],\n"
    "               uint i [[thread_position_in_grid]]) { out[i] = unpack(in[i], form); }\n"
    "struct V { float4 p [[position]]; uint v [[flat]]; };\n"
    "vertex V vs(uint vid [[vertex_id]], device const uint *in [[buffer(0)]]) {\n"
    "    V o; o.p = float4((vid % 256 + 0.5) / 128.0 - 1.0, 1.0 - (vid / 256 + 0.5) / 128.0, 0, 1); o.v = in[vid]; return o;\n"
    "}\n"
    "fragment float4 fs(V v [[stage_in]], constant uint &form [[buffer(0)]]) { return unpack(v.v, form); }\n";

static const char *const kNames[] = {"unpack_snorm2x16_to_float", "unpack_unorm2x16_to_float", "unpack_snorm4x8_to_float",
                                     "unpack_unorm4x8_to_float"};

static float exact(uint32_t packed, unsigned form, unsigned component) {
    if (form < 2) {
        if (component > 1) return 0;
        uint16_t field = (uint16_t)(packed >> (16 * component));
        return form == 0 ? fmaxf((float)((double)(int16_t)field / 32767.0), -1.0f) : (float)((double)field / 65535.0);
    }
    uint8_t field = (uint8_t)(packed >> (8 * component));
    return form == 2 ? fmaxf((float)((double)(int8_t)field / 127.0), -1.0f) : (float)((double)field / 255.0);
}

static long ulps(float a, float b) {
    int32_t ia, ib;
    memcpy(&ia, &a, 4);
    memcpy(&ib, &b, 4);
    if ((ia < 0) != (ib < 0)) return a == b ? 0 : LONG_MAX;
    return labs((long)ia - ib);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a12-amd-unpack-norm";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"ck"] error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!cps || !rps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        enum { N = 65536 };
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> in = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        // Low half: every value; high half: every value in reverse. For the 4x8 forms that's every byte in every position.
        for (uint32_t i = 0; i < N; i++) ((uint32_t *)in.contents)[i] = i | ((N - 1 - i) << 16);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:256 height:256
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        float *fragment = malloc(N * 16);
        char report[512] = "";
        int failures = 0;
        for (uint32_t form = 0; form < 4; form++) {
            id<MTLBuffer> out = [dev newBufferWithLength:N * 16 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:cps];
            [ce setBuffer:in offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce setBytes:&form length:4 atIndex:2];
            [ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:rps];
            [re setVertexBuffer:in offset:0 atIndex:0];
            [re setFragmentBytes:&form length:4 atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:N];
            [re endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be synchronizeResource:rt];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            [rt getBytes:fragment bytesPerRow:256 * 16 fromRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0];
            for (int stage = 0; stage < 2; stage++) {
                const float *r = stage ? fragment : (const float *)out.contents;
                long worst = 0;
                uint32_t worstValue = 0;
                unsigned worstComponent = 0;
                for (uint32_t i = 0; i < N; i++)
                    for (unsigned c = 0; c < 4; c++) {
                        long u = ulps(r[i * 4 + c], exact(((uint32_t *)in.contents)[i], form, c));
                        if (u > worst) worst = u, worstValue = ((uint32_t *)in.contents)[i], worstComponent = c;
                    }
                if (worst > 1) {
                    failures++;
                    char line[160];
                    snprintf(line, sizeof line, "%s%s in %s: %ld ulp (0x%08x.%u)", failures > 1 ? "; " : "", kNames[form],
                             stage ? "fragment" : "compute", worst == LONG_MAX ? -1 : worst, worstValue, worstComponent);
                    strlcat(report, line, sizeof report);
                }
            }
        }
        free(fragment);
        if (failures) return FAIL(bug, "%s: %s", dev.name.UTF8String, report);
        return PASS(bug, "%s: snorm/unorm 2x16 and 4x8 unpacks within 1 ulp in compute and fragment functions", dev.name.UTF8String);
    }
}
