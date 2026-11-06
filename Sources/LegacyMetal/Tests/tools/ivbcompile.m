// ivbcompile <file.metal|file.metallib> kernel <name> | render <vertex> <fragment>: compile-only. The Haswell driver's
// pipeline creation is stubbed (it can't decode Ivy Bridge binaries): reaching it means the compiler finished, and the
// stub returns nil, so nothing ever runs on the GPU. Vertex descriptors are synthesized from the vertex function.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>
static int compiled;
static id stubCompute(id self, SEL _cmd, id descriptor, id variant) { compiled++; printf("COMPILED (compute)\n"); fflush(stdout); return nil; }
static id stubRender(id self, SEL _cmd, id descriptor, id vertex, id fragment) { compiled++; printf("COMPILED (render)\n"); fflush(stdout); return nil; }
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> d = nil;
        for (id<MTLDevice> x in MTLCopyAllDevices()) if ([x.name containsString:@"Intel"]) d = x;
        Class dev = objc_getClass("MTLIGAccelDevice");
        method_setImplementation(class_getInstanceMethod(dev, sel_registerName("newComputePipelineWithDescriptor:variant:")), (IMP)stubCompute);
        method_setImplementation(class_getInstanceMethod(dev, sel_registerName("newRenderPipelineWithDescriptor:vertexVariant:fragmentVariant:")), (IMP)stubRender);
        NSError *e = nil;
        NSString *path = @(argv[1]);
        id<MTLLibrary> lib;
        if ([path hasSuffix:@".metal"]) {
            NSString *src = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] stringByAppendingFormat:@"\n// %d\n", getpid()];
            lib = [d newLibraryWithSource:src options:nil error:&e];
        } else lib = [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e];
        if (!lib) { printf("FRONT-END ERROR %s\n", e.localizedDescription.UTF8String); return 1; }
        if (!strcmp(argv[2], "kernel")) {
            [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@(argv[3])] error:&e];
        } else {
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@(argv[3])];
            pd.fragmentFunction = [lib newFunctionWithName:@(argv[4])];
            MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
            NSUInteger n = 0;
            for (MTLVertexAttribute *a in pd.vertexFunction.vertexAttributes) {
                if (!a.active) continue;
                MTLVertexFormat f = a.attributeType == MTLDataTypeFloat3 ? MTLVertexFormatFloat3 : a.attributeType == MTLDataTypeFloat2 ? MTLVertexFormatFloat2
                                  : a.attributeType == MTLDataTypeFloat ? MTLVertexFormatFloat : MTLVertexFormatFloat4;
                vd.attributes[a.attributeIndex].format = f;
                vd.attributes[a.attributeIndex].bufferIndex = 1 + a.attributeIndex;
                vd.layouts[1 + a.attributeIndex].stride = 16;
                n++;
            }
            if (n) pd.vertexDescriptor = vd;
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            [d newRenderPipelineStateWithDescriptor:pd error:&e];
        }
        if (!compiled) printf("COMPILE FAILED %s\n", e.localizedDescription.UTF8String);
        return compiled ? 0 : 1;
    }
}
