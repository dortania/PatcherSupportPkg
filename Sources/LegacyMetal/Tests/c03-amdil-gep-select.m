// c03-amdil-gep-select (libAMDIL902 patch 4; AMD GCN on the 12.5 stack, every GCN generation): a field of a struct in
// a small dynamically indexed private array (`S w[2]; ... w[s].count += 1; ... read w[s].count`) reads back a stale
// value. libAMDIL902's IL GEP Select pass (ILGEPSelect::runOnFunction) rewrites each load through such a GEP into loads
// of every element + selects on the index, but builds all of them at the GEP: when LLVM computed &w[s].count once
// and reused it for every access, loads after the stores read the values from before them (here closure_len came out
// 0, or whatever an earlier wavefront left in that scratch slot). The fix moves the pass's IRBuilder to each load.
// (Found while trying to reproduce a03 with a small shader: the fragment-shader variant of this kernel. With the
// Intel GPU its compile hits an internal compiler error, a different problem not looked at yet.)
// Stock OCLP: FAIL. Fixed (patched libAMDIL902): PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct GBufferWriter { float4 N[4]; uchar normal_len; uchar closure_len; ushort pad; float data[24]; };\n"
    "struct VO { float4 pos [[position]]; };\n"
    "vertex VO vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VO o; o.pos = float4(p[vid], 0, 1); return o; }\n"
    // A fragment shader, as EEVEE's G-buffer pass (SC writes compute-shader scratch with GLC, pixel-shader scratch without).
    "fragment float4 fs(VO in [[stage_in]], device float4 *out [[buffer(0)]], constant uint &n [[buffer(1)]]) {\n"
    "  uint gid = uint(in.pos.y) * 256u + uint(in.pos.x);\n"
    "  GBufferWriter w[2];\n"                       // dynamically indexed: kept in scratch memory
    "  uint s = (gid >> 3) & n & 1u;\n"
    "  w[s].normal_len = 0; w[s].closure_len = 0;\n"
    "  for (int i = 0; i < 24; i++) w[s].data[i] = float(gid + uint(i));\n"
    "  for (int i = 0; i < 4; i++) w[s].N[i] = float4(0.0f);\n"
    "  for (uint i = 0; i < n + 1u; i++) {\n"      // two normals
    "    w[s].N[w[s].normal_len] = float4(float(gid), float(i), 0.0f, 1.0f);\n"
    "    w[s].normal_len += 1;\n"
    "    w[s].closure_len += 1;\n"
    "  }\n"
    "  w[s].N[w[s].normal_len] = float4(-1.0f);\n"  // the thickness, after the normals
    "  out[gid * 3] = w[s].N[0]; out[gid * 3 + 1] = w[s].N[1];\n"
    "  out[gid * 3 + 2] = float4(float(w[s].normal_len), float(w[s].closure_len), w[s].data[s * 3u], w[s].N[2].x);\n"
    "  return w[s].N[0];\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "c03-amdil-gep-select";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:256 height:256 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        const uint32_t N = 65536, n = 1;
        id<MTLBuffer> out = [dev newBufferWithLength:N * 48 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> host = [dev newBufferWithLength:N * 48 options:MTLResourceStorageModeShared];
        uint32_t bad = 0, firstBad = 0, runs = 8;
        float firstValues[12] = {0};
        for (uint32_t run = 0; run < runs; run++) {
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:ps]; [e setFragmentBuffer:out offset:0 atIndex:0]; [e setFragmentBytes:&n length:4 atIndex:1];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromBuffer:out sourceOffset:0 toBuffer:host destinationOffset:0 size:N * 48];
            [b endEncoding];
            reproRun(cb);
            const float *o = host.contents;
            for (uint32_t g = 0; g < N; g++) {
                const float *v = o + g * 12;
                uint32_t s = (g >> 3) & n & 1u;
                BOOL ok = v[0] == g && v[1] == 0 && v[3] == 1 && v[4] == g && v[5] == 1 && v[7] == 1 && v[8] == 2 && v[9] == 2 &&
                          v[10] == (float)(g + s * 3) && v[11] == -1;
                if (!ok && !bad++) { firstBad = g; memcpy(firstValues, v, sizeof firstValues); }
            }
        }
        if (bad) {
            const float *v = firstValues;
            return FAIL(bug, "%s: %u of %u fragments read a stale private value (first: pixel %u: N[0] = %g %g, N[1] = %g %g, normal_len %g, "
                        "closure_len %g, N[2] %g; want N[0] = %u 0, N[1] = %u 1, 2, 2, -1)", dev.name.UTF8String, bad, N * runs, firstBad,
                        v[0], v[1], v[4], v[5], v[8], v[9], v[11], firstBad, firstBad);
        }
        return PASS(bug, "%s: %u fragments x %u runs: every read-after-write of scratch memory current", dev.name.UTF8String, N, runs);
    }
}
