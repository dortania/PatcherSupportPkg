// s02-reflection (MetalOldCompat item 2): pipeline reflection on a GPU whose shaders the current (macOS 14+) compiler
// builds. The compiler wraps reflection data in a newer container (CompilerOutputReflectionBlock) that MetalOld can't
// read, so render/compute pipeline reflection (MTLPipelineOptionBindingInfo | BufferTypeInfo, used by Blender, Godot,
// MoltenVK...) is missing or wrong, or the process crashes. Checks binding names, indices and a buffer's struct layout.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct U { float4x4 mvp; float4 color; int2 flags[3]; };\n"
    "struct VI { float3 pos [[attribute(0)]]; float2 uv [[attribute(2)]]; };\n"
    "struct VO { float4 pos [[position]]; float2 uv; };\n"
    "vertex VO vs(VI in [[stage_in]], constant U &u [[buffer(1)]], const device float *extra [[buffer(4)]]) {\n"
    "  VO o; o.pos = u.mvp * float4(in.pos, 1) + extra[0]; o.uv = in.uv; return o; }\n"
    "fragment float4 fs(VO in [[stage_in]], constant U &u [[buffer(1)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return u.color * t.sample(s, in.uv); }\n"
    "kernel void cs(device float *out [[buffer(0)]], constant U &u [[buffer(2)]], texture2d<float, access::write> img [[texture(1)]],\n"
    "               uint2 gid [[thread_position_in_grid]]) { out[gid.x] = u.color.x; img.write(u.color, gid); }\n";

static id<MTLBinding> find(NSArray<id<MTLBinding>> *bindings, NSString *name) {
    for (id<MTLBinding> b in bindings) if ([b.name isEqualToString:name]) return b;
    return nil;
}

// The struct U as reflected: mvp at 0, color at 64, flags[3] (int2, stride 8) at 80.
static const char *checkU(id<MTLBinding> b, NSUInteger index) {
    if (!b) return "binding 'u' missing";
    if (b.type != MTLBindingTypeBuffer || b.index != index) return "binding 'u' has the wrong type or index";
    MTLStructType *st = ((id<MTLBufferBinding>)b).bufferStructType;
    if (!st) return "no struct type for 'u'";
    MTLStructMember *mvp = [st memberByName:@"mvp"], *color = [st memberByName:@"color"], *flags = [st memberByName:@"flags"];
    if (!mvp || !color || !flags) return "struct members missing";
    if (mvp.offset != 0 || color.offset != 64 || flags.offset != 80) return "struct member offsets wrong";
    if (!flags.arrayType || flags.arrayType.arrayLength != 3 || flags.arrayType.stride != 8) return "array member wrong";
    return NULL;
}

static int child(int argc, char **argv) {
    id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) { printf("library: %s\n", err.localizedDescription.UTF8String); return 3; }
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3; vd.attributes[0].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat2; vd.attributes[2].bufferIndex = 0; vd.attributes[2].offset = 12;
    vd.layouts[0].stride = 20;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    MTLPipelineOption opts = MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo;
    MTLRenderPipelineReflection *refl = nil;
    if (![dev newRenderPipelineStateWithDescriptor:d options:opts reflection:&refl error:&err]) { printf("render pipeline: %s\n", err.localizedDescription.UTF8String); return 3; }
    if (!refl) { printf("render pipeline reflection is nil\n"); return 4; }
    const char *problem = checkU(find(refl.vertexBindings, @"u"), 1);
    if (!problem && !find(refl.vertexBindings, @"extra")) problem = "vertex binding 'extra' missing";
    if (!problem && !find(refl.fragmentBindings, @"t")) problem = "fragment texture 't' missing";
    if (problem) { printf("render reflection: %s\n", problem); return 4; }
    MTLComputePipelineReflection *crefl = nil;
    if (![dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cs"] options:opts reflection:&crefl error:&err]) { printf("compute pipeline: %s\n", err.localizedDescription.UTF8String); return 3; }
    if (!crefl) { printf("compute pipeline reflection is nil\n"); return 4; }
    problem = checkU(find(crefl.bindings, @"u"), 2);
    if (!problem && !find(crefl.bindings, @"img")) problem = "texture 'img' missing";
    if (problem) { printf("compute reflection: %s\n", problem); return 4; }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (reproChildMode(argc, argv)) return child(argc, argv);
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP("s02-reflection", "no such GPU");
        int status = reproRunChild(argc, argv, "reflect");
        if (status == 0) return PASS("s02-reflection", "%s: render and compute reflection complete (bindings, struct layout)", dev.name.UTF8String);
        return FAIL("s02-reflection", "%s: %s", dev.name.UTF8String,
                    status == 4 ? "reflection missing or wrong (see line above)" : status == 3 ? "pipeline creation failed (see line above)" : reproChildStatus(status));
    }
}
