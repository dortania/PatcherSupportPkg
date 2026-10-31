// a05-escaped-texture-pointer (AMD and Intel adapters): a texture or sampler reached through a pointer that was stored
// to memory and loaded back. MSL texture and sampler array arguments are byval arrays of
// handles in AIR, which libAMDIL902 places in the argument table (user data API slots 6/7, global memory). It lowers a
// handle load from an element of such an argument to a global load, but a handle load through a pointer it can't
// trace back to the argument to a scratch load. ANGLE (Chrome, Safari) keeps `thread texture2d *` / `thread sampler *`
// pairs for every GLSL sampler in an array of structs and, for sampler arrays indexed in a loop, loads them with a
// runtime index: the sample then uses a descriptor read from the wrong memory. It returns 0 (WebGL conformance
// glsl/bugs/sampler-array-using-loop-index: "expected 64,32,16,9 was 0,0,0,0"), and once in a Chrome conformance run
// it hung the GPU. AMD: any GCN GPU on the 12.5 stack. Intel (3802 compiler): IGILTextureTypeEncode can't follow such
// a texture and the compiler service crashes (null + 0x20), so the pipeline fails; with ANGLE's shader only on this
// stack (native macOS 12.7.6 compiles it: its front end gives other AIR). Two 1x1 textures (40,20,10,5), (24,12,6,4):
//   1. ANGLE's shape: loop i = 1..2 summing env[clamp(i - 1, 0, 1)] -> 64,32,16,9
//   2. env[n] with n = 0 and n = 1 from a buffer -> each texture's own color
// Stock OCLP: FAIL (AMD: rarely a GPU restart instead; Intel: pipeline error). Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Env { thread texture2d<float> *texture; thread sampler *sampler; };\n"
    "struct VO { float4 p [[position]]; };\n"
    "vertex VO vs(uint v [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VO o; o.p = float4(p[v], 0, 1); return o; }\n"
    "fragment float4 loop(array<texture2d<float>, 2> t [[texture(0)]], array<sampler, 2> s [[sampler(0)]], constant uint &n [[buffer(0)]]) {\n"
    "  array<Env, 2> env; env[0].texture = &t[0]; env[0].sampler = &s[0]; env[1].texture = &t[1]; env[1].sampler = &s[1];\n"
    "  float4 c = 0;\n"
    "  for (int i = 1; i < 3; i++) { if (c.x > 255.0f) { c.x = 255.0f; break; } Env e = env[clamp(i - 1, 0, 1)]; c += e.texture->sample(*e.sampler, float2(0.5)); }\n"
    "  return c; }\n"
    "fragment float4 pick(array<texture2d<float>, 2> t [[texture(0)]], array<sampler, 2> s [[sampler(0)]], constant uint &n [[buffer(0)]]) {\n"
    "  array<Env, 2> env; env[0].texture = &t[0]; env[0].sampler = &s[0]; env[1].texture = &t[1]; env[1].sampler = &s[1];\n"
    "  Env e = env[n & 1]; return e.texture->sample(*e.sampler, float2(0.5)); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a05-escaped-texture-pointer";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        uint8_t c0[4] = {40, 20, 10, 5}, c1[4] = {24, 12, 6, 4};
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        id<MTLTexture> t0 = [dev newTextureWithDescriptor:td], t1 = [dev newTextureWithDescriptor:td];
        [t0 replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:c0 bytesPerRow:4];
        [t1 replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:c1 bytesPerRow:4];
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        struct { const char *function; uint32_t n; uint8_t want[4]; } cases[] = {
            {"loop", 0, {64, 32, 16, 9}}, {"pick", 0, {40, 20, 10, 5}}, {"pick", 1, {24, 12, 6, 4}}};
        char problems[512] = "";
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"vs"];
            pd.fragmentFunction = [lib newFunctionWithName:@(cases[i].function)];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!ps) return FAIL(bug, "%s pipeline: %s", cases[i].function, err.localizedDescription.UTF8String);
            MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
            rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModeManaged;
            id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:ps];
            [re setFragmentBytes:&cases[i].n length:4 atIndex:0];
            [re setFragmentTexture:t0 atIndex:0]; [re setFragmentTexture:t1 atIndex:1];
            [re setFragmentSamplerState:sampler atIndex:0]; [re setFragmentSamplerState:sampler atIndex:1];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be synchronizeResource:rt]; [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed (GPU restart?)", cases[i].function);
            uint8_t px[4];
            [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
            if (memcmp(px, cases[i].want, 4))
                snprintf(problems + strlen(problems), sizeof problems - strlen(problems), "%s%s(n=%u): %d,%d,%d,%d, want %d,%d,%d,%d",
                         *problems ? "; " : "", cases[i].function, cases[i].n, px[0], px[1], px[2], px[3],
                         cases[i].want[0], cases[i].want[1], cases[i].want[2], cases[i].want[3]);
        }
        if (*problems) return FAIL(bug, "%s: textures sampled through stored pointers: %s", dev.name.UTF8String, problems);
        return PASS(bug, "%s: textures and samplers sampled correctly through pointers loaded from an array", dev.name.UTF8String);
    }
}
