// c02-amdil-color-input (libAMDIL902 parser fix, patches 2 and 3; AMD GCN on the 12.5 stack): fragment functions with
// a [[color(n)]] *input* (framebuffer fetch; Blender's MSL declares one for tile inputs even on GPUs where it's unused).
// The macOS 14+ compiler writes such inputs as `"air.render_target", <attachment>` without a blending index:
// libAMDIL902's initShaderArgType aborts with "Unsupported 'air.render_target' metadata configuration", and with
// raster_order_group the next key string is read as the blending index (crash). Blender 4.x can't build any material.
// Builds the same pipeline with an unused colour input, with raster_order_group, and (control) without.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const common = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VO { float4 pos [[position]]; };\n"
    "vertex VO vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; VO o; o.pos = float4(p[vid], 0, 1); return o; }\n"
    "struct Out { float4 c0 [[color(0)]]; uint c1 [[color(1)]]; };\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "c02-amdil-color-input";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSArray *variants = @[
            @[@"no colour input (control)", @"fragment Out fs(VO in [[stage_in]]) { Out o; o.c0 = float4(1); o.c1 = 7; return o; }"],
            @[@"unused [[color(1)]] input", (@"struct TI { uint g [[color(1)]]; };\n"
                                             "fragment Out fs(VO in [[stage_in]], TI tile_in) { Out o; o.c0 = float4(1); o.c1 = 7; return o; }")],
            @[@"[[color(1), raster_order_group(0)]] input", (@"struct TI { uint g [[color(1), raster_order_group(0)]]; };\n"
                                             "fragment Out fs(VO in [[stage_in]], TI tile_in) { Out o; o.c0 = float4(1); o.c1 = 7; return o; }")],
        ];
        NSMutableString *failed = [NSMutableString string];
        for (NSArray *v in variants) {
            NSError *err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:[common stringByAppendingString:v[1]]] options:nil error:&err];
            id<MTLRenderPipelineState> ps = nil;
            if (lib) {
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                d.vertexFunction = [lib newFunctionWithName:@"vs"];
                d.fragmentFunction = [lib newFunctionWithName:@"fs"];
                d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
                d.colorAttachments[1].pixelFormat = MTLPixelFormatR32Uint;
                ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
            }
            if (!ps) [failed appendFormat:@"%@%@: %@", failed.length ? @"; " : @"", v[0], err.localizedDescription];
        }
        if (failed.length) return FAIL(bug, "%s: %s", dev.name.UTF8String, failed.UTF8String);
        return PASS(bug, "%s: pipelines with [[color(n)]] fragment inputs build", dev.name.UTF8String);
    }
}
