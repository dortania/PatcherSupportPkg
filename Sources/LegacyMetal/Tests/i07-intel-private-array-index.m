// i07-intel-private-array-index (Intel adapter, IntelTextureAtomics.dylib): a private array inside a struct, indexed with a
// variable, in a vertex or fragment function with the 3802 Intel compiler. The array becomes an indexable register array,
// which the back end addresses two ways (raw scratch byte addresses for constant-offset stores, x0[i] for variable
// indices), so elements written one way and read the other come back 0 or stale. ANGLE declares every GLSL array that way
// (WebGL unary-minus-operator-in-dynamic-loop, dEQP shaderstruct array_member_dynamic_index). Vertex and fragment
// functions fill int arrays (struct-wrapped with 3 and 8 elements, and a plain one as the control) at constant indices
// and sum them in a loop bounded by a uniform.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i07-intel-private-array-index";
        id<MTLDevice> d = reproDevice(argc, argv, "Intel");
        if (!d) return SKIP(bug, "no such GPU");
        const char *decls[] = {"Arr3 a;", "int a3[3];", "Arr8 a;"};
        const char *refs[] = {"a.v", "a3", "a.v"};
        int sizes[] = {3, 3, 8};
        for (int c = 0; c < 3; c++) for (int stage = 0; stage < 2; stage++) {
            NSString *fill = [NSString stringWithFormat:@"%s for (int k = 0; k < %d; k++) %s[k] = k == 0 ? u.x : k == 1 ? u.y : u.z + k; int result = 0; for (int i = 0; i < u.w; i++) result += %s[i];",
                              decls[c], sizes[c], refs[c], refs[c]];
            NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nstruct Arr3 { int v[3]; }; struct Arr8 { int v[8]; };\n"
                "struct V { float4 p [[position]]; float r; };\n"
                "vertex V v(uint id [[vertex_id]], constant int4 &u [[buffer(0)]]) { V out; float2 p = float2((id << 1) & 2, id & 2); out.p = float4(p * 2 - 1, 0, 1); %@ out.r = float(result); return out; }\n"
                "fragment float4 f(V in [[stage_in]], constant int4 &u [[buffer(0)]]) { %@ return float4(in.r, float(result), 0, 1); }\n// %d %d%@\n",
                stage == 0 ? fill : @"int result = 0;", stage == 1 ? fill : @"int result = 0; (void)u;", c, stage, reproUniqueComment()];
            NSError *e = nil;
            id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
            if (!lib) return FAIL(bug, "%s: front end: %s", d.name.UTF8String, e.localizedDescription.UTF8String);
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"v"]; pd.fragmentFunction = [lib newFunctionWithName:@"f"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            id<MTLRenderPipelineState> rps = [d newRenderPipelineStateWithDescriptor:pd error:&e];
            if (!rps) return FAIL(bug, "%s: no pipeline: %s", d.name.UTF8String, e.localizedDescription.UTF8String);
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:4 height:4 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeManaged;
            id<MTLTexture> t = [d newTextureWithDescriptor:td];
            int u[4] = {1, 2, 10, sizes[c]};
            int want = 0; for (int k = 0; k < sizes[c]; k++) want += k == 0 ? 1 : k == 1 ? 2 : 10 + k;
            id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:rps]; [re setVertexBytes:u length:16 atIndex:0]; [re setFragmentBytes:u length:16 atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:t]; [bl endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", d.name.UTF8String);
            float px[4]; [t getBytes:px bytesPerRow:64 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
            float got = stage == 0 ? px[0] : px[1];
            if (got != want) return FAIL(bug, "%s: %s array of %d ints, summed in a %s function loop: %g, want %d", d.name.UTF8String, c == 1 ? "plain" : "struct-wrapped", sizes[c], stage ? "fragment" : "vertex", got, want);
        }
        return PASS(bug, "%s: variable-index private arrays (struct-wrapped and plain, 3 and 8 ints) read back in vertex and fragment functions", d.name.UTF8String);
    }
}
