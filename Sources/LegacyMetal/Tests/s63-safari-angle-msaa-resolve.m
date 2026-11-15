// s63-safari-angle-msaa-resolve (shim item 13): Safari's WebGL runs on WebKit's own ANGLE (libANGLE-shared.dylib),
// which loads its internal shaders (blits, clears, multisample resolves, buffer/texture copies) from a prebuilt
// metallib. Safari 18.6 on Sequoia ships one built for AIR 2.7 (air64-apple-macosx15.8.0), which this stack's compiler
// can't specialize ("air version set to 2.7.0, but expecting 2.6"), so every antialiased WebGL context failed its
// multisample resolve with GL_INVALID_OPERATION and showed nothing. This drives WebKit's ANGLE through its EGL_/GL_
// entry points like WebKit's antialiased drawing buffer: a 4x multisampled color and depth framebuffer, a clear and
// a draw reading a uniform block, each resolved with glBlitFramebuffer and read back.
// With S63_METALLIB=<file> (a saved copy of that library, e.g. Safari 18.6's on a Mac with a newer Safari), it instead
// loads the file through tools/angle-caller/libANGLE-shared.dylib, which item 13 takes for WebKit's ANGLE, and checks that
// the library it gets back is usable: it has the file's functions and ANGLE's clear pipeline specializes and builds
// (the AIR 2.7 library itself fails to specialize). Argument in that mode: GPU name substring (default: the default GPU).
// Stock OCLP on Sequoia with Safari 18.6: FAIL. Fixed: PASS. Tahoe's compiler reads AIR 2.7, and newer Safaris' libraries
// take the original path, so there it passes either way. SKIP without WebKit's ANGLE. Runs on the GPU ANGLE picks (item 11
// gives it the family-2 GPU on dual-GPU Macs; the result line names the renderer).
#import "repro.h"
#include <dlfcn.h>

typedef void *P;
typedef int32_t I;
typedef uint32_t U;
static void *angle;
#define F(ret, name, ...) static ret (*name)(__VA_ARGS__);
F(P, EGL_GetPlatformDisplayEXT, U, P, const I *) F(U, EGL_Initialize, P, I *, I *) F(U, EGL_ChooseConfig, P, const I *, P *, I, I *)
F(P, EGL_CreatePbufferSurface, P, P, const I *) F(P, EGL_CreateContext, P, P, P, const I *) F(U, EGL_MakeCurrent, P, P, P, P)
F(U, EGL_BindAPI, U) F(void, GL_ClearColor, float, float, float, float) F(void, GL_Clear, U) F(void, GL_ReadPixels, I, I, I, I, U, U, void *)
F(U, GL_GetError, void) F(U, GL_CreateShader, U) F(void, GL_ShaderSource, U, I, const char *const *, const I *) F(void, GL_CompileShader, U)
F(U, GL_CreateProgram, void) F(void, GL_AttachShader, U, U) F(void, GL_LinkProgram, U) F(void, GL_GetProgramiv, U, U, I *) F(void, GL_UseProgram, U)
F(void, GL_GenBuffers, I, U *) F(void, GL_BindBuffer, U, U) F(void, GL_BufferData, U, intptr_t, const void *, U)
F(U, GL_GetUniformBlockIndex, U, const char *) F(void, GL_UniformBlockBinding, U, U, U) F(void, GL_BindBufferBase, U, U, U)
F(void, GL_Viewport, I, I, I, I) F(void, GL_DrawArrays, U, I, I) F(const char *, GL_GetString, U) F(void, GL_GenFramebuffers, I, U *)
F(void, GL_BindFramebuffer, U, U) F(void, GL_GenRenderbuffers, I, U *) F(void, GL_BindRenderbuffer, U, U)
F(void, GL_RenderbufferStorageMultisample, U, I, U, I, I) F(void, GL_FramebufferRenderbuffer, U, U, U, U) F(void, GL_GenTextures, I, U *)
F(void, GL_BindTexture, U, U) F(void, GL_TexStorage2D, U, I, U, I, I) F(void, GL_FramebufferTexture2D, U, U, U, U, I)
F(void, GL_BlitFramebuffer, I, I, I, I, I, I, I, I, U, U)
#define L(name) if (!(name = dlsym(angle, #name))) return SKIP(bug, "WebKit's ANGLE has no " #name);

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s63-safari-angle-msaa-resolve";
        if (getenv("S63_METALLIB")) {  // a saved ANGLE internal-shader library, loaded as WebKit's ANGLE loads it
            id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();
            NSData *bytes = [NSData dataWithContentsOfFile:@(getenv("S63_METALLIB"))];
            NSString *helper = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../tools/angle-caller/libANGLE-shared.dylib"];
            void *caller = dlopen(helper.UTF8String, RTLD_NOW);
            id (*load)(id<MTLDevice>, NSData *, NSError **) = caller ? dlsym(caller, "s63LoadAngleLibrary") : NULL;
            if (!dev || !bytes || !load) return SKIP(bug, "S63_METALLIB: no device, file or %s", helper.UTF8String);
            NSError *error = nil;
            id<MTLLibrary> library = load(dev, bytes, &error);
            if (!library) return FAIL(bug, "%s: S63_METALLIB didn't load: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
            MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
            uint32_t one = 1;
            [constants setConstantValue:&one type:MTLDataTypeUInt atIndex:0];  // kNumColorOutputs
            id<MTLFunction> vs = [library newFunctionWithName:@"clearVS" constantValues:constants error:&error];
            id<MTLFunction> fs = vs ? [library newFunctionWithName:@"clearFloatFS" constantValues:constants error:&error] : nil;
            if (!fs) return FAIL(bug, "%s: ANGLE's clear shaders from S63_METALLIB don't specialize: %s", dev.name.UTF8String,
                                 error.localizedDescription.UTF8String);
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = vs;
            pd.fragmentFunction = fs;
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            if (![dev newRenderPipelineStateWithDescriptor:pd error:&error])
                return FAIL(bug, "%s: ANGLE's clear pipeline from S63_METALLIB: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
            return PASS(bug, "%s: ANGLE library from S63_METALLIB (%lu functions) specializes and builds ANGLE's clear pipeline",
                        dev.name.UTF8String, (unsigned long)library.functionNames.count);
        }
        MTLCreateSystemDefaultDevice();  // as WebCore does in Safari's GPU process before ANGLE starts
        angle = dlopen("/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/"
                       "libANGLE-shared.dylib", RTLD_NOW);
        if (!angle) return SKIP(bug, "no WebKit ANGLE (libANGLE-shared.dylib)");
        L(EGL_GetPlatformDisplayEXT) L(EGL_Initialize) L(EGL_ChooseConfig) L(EGL_CreatePbufferSurface) L(EGL_CreateContext) L(EGL_MakeCurrent)
        L(EGL_BindAPI) L(GL_ClearColor) L(GL_Clear) L(GL_ReadPixels) L(GL_GetError) L(GL_CreateShader) L(GL_ShaderSource) L(GL_CompileShader)
        L(GL_CreateProgram) L(GL_AttachShader) L(GL_LinkProgram) L(GL_GetProgramiv) L(GL_UseProgram) L(GL_GenBuffers) L(GL_BindBuffer)
        L(GL_BufferData) L(GL_GetUniformBlockIndex) L(GL_UniformBlockBinding) L(GL_BindBufferBase) L(GL_Viewport) L(GL_DrawArrays) L(GL_GetString)
        L(GL_GenFramebuffers) L(GL_BindFramebuffer) L(GL_GenRenderbuffers) L(GL_BindRenderbuffer) L(GL_RenderbufferStorageMultisample)
        L(GL_FramebufferRenderbuffer) L(GL_GenTextures) L(GL_BindTexture) L(GL_TexStorage2D) L(GL_FramebufferTexture2D) L(GL_BlitFramebuffer)
        const I displayAttributes[] = {0x3203, 0x3489, 0x3038};  // EGL_PLATFORM_ANGLE_TYPE_ANGLE: METAL
        P display = EGL_GetPlatformDisplayEXT(0x3202, 0, displayAttributes);
        I major, minor, configs;
        if (!display || !EGL_Initialize(display, &major, &minor)) return FAIL(bug, "ANGLE's Metal display didn't initialize");
        const I configAttributes[] = {0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038};
        P config;
        EGL_ChooseConfig(display, configAttributes, &config, 1, &configs);
        EGL_BindAPI(0x30A0);
        const I surfaceAttributes[] = {0x3057, 64, 0x3056, 64, 0x3038};
        P surface = EGL_CreatePbufferSurface(display, config, surfaceAttributes);
        const I contextAttributes[] = {0x3098, 3, 0x33AC, 1, 0x3038};  // ES 3, WebGL compatibility, as WebKit asks
        P context = EGL_CreateContext(display, config, 0, contextAttributes);
        if (!context || !EGL_MakeCurrent(display, surface, surface, context)) return FAIL(bug, "no ANGLE ES 3 context");
        const char *renderer = GL_GetString(0x1F01);
        U multisampled, buffers[2], resolved, texture;
        GL_GenFramebuffers(1, &multisampled);
        GL_GenRenderbuffers(2, buffers);
        GL_GenFramebuffers(1, &resolved);
        GL_GenTextures(1, &texture);
        GL_BindRenderbuffer(0x8D41, buffers[0]);
        GL_RenderbufferStorageMultisample(0x8D41, 4, 0x8058, 64, 64);  // RGBA8
        GL_BindRenderbuffer(0x8D41, buffers[1]);
        GL_RenderbufferStorageMultisample(0x8D41, 4, 0x88F0, 64, 64);  // DEPTH24_STENCIL8
        GL_BindFramebuffer(0x8D40, multisampled);
        GL_FramebufferRenderbuffer(0x8D40, 0x8CE0, 0x8D41, buffers[0]);
        GL_FramebufferRenderbuffer(0x8D40, 0x821A, 0x8D41, buffers[1]);
        GL_BindTexture(0x0DE1, texture);
        GL_TexStorage2D(0x0DE1, 1, 0x8058, 64, 64);
        GL_BindFramebuffer(0x8D40, resolved);
        GL_FramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, texture, 0);
        uint8_t px[4];
        // a clear, resolved
        GL_BindFramebuffer(0x8D40, multisampled);
        GL_ClearColor(0, 1, 0, 1);
        GL_Clear(0x4000 | 0x100);
        GL_BindFramebuffer(0x8CA8, multisampled);
        GL_BindFramebuffer(0x8CA9, resolved);
        GL_BlitFramebuffer(0, 0, 64, 64, 0, 0, 64, 64, 0x4000, 0x2600);
        U error = GL_GetError();
        GL_BindFramebuffer(0x8D40, resolved);
        GL_ReadPixels(0, 0, 1, 1, 0x1908, 0x1401, px);
        if (error || px[0] != 0 || px[1] != 255 || px[2] != 0 || px[3] != 255)
            return FAIL(bug, "%s: multisampled clear resolved by glBlitFramebuffer: GL error %#x, pixel %u %u %u %u, want 0 255 0 255",
                        renderer, error, px[0], px[1], px[2], px[3]);
        // a draw reading a uniform block, resolved
        const char *vs = "#version 300 es\nvoid main(){vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3));gl_Position=vec4(p[gl_VertexID],0,1);}";
        const char *fs = "#version 300 es\nprecision highp float; layout(std140) uniform U{vec4 color; vec4 color2;}; out vec4 o;"
                         " void main(){o=color+color2;}";
        U program = GL_CreateProgram(), v = GL_CreateShader(0x8B31), f = GL_CreateShader(0x8B30);
        GL_ShaderSource(v, 1, &vs, 0);
        GL_ShaderSource(f, 1, &fs, 0);
        GL_CompileShader(v);
        GL_CompileShader(f);
        GL_AttachShader(program, v);
        GL_AttachShader(program, f);
        GL_LinkProgram(program);
        I linked = 0;
        GL_GetProgramiv(program, 0x8B82, &linked);
        if (!linked) return FAIL(bug, "%s: the uniform-block program didn't link", renderer);
        GL_UseProgram(program);
        U block;
        GL_GenBuffers(1, &block);
        GL_BindBuffer(0x8A11, block);
        const float values[8] = {0.25f, 0.5f, 0, 1, 0.5f, 0, 0.25f, 0};
        GL_BufferData(0x8A11, sizeof values, values, 0x88E4);
        GL_UniformBlockBinding(program, GL_GetUniformBlockIndex(program, "U"), 0);
        GL_BindBufferBase(0x8A11, 0, block);
        GL_BindFramebuffer(0x8D40, multisampled);
        GL_Viewport(0, 0, 64, 64);
        GL_ClearColor(0, 0, 0, 0);
        GL_Clear(0x4000 | 0x100);
        GL_DrawArrays(4, 0, 3);
        GL_BindFramebuffer(0x8CA8, multisampled);
        GL_BindFramebuffer(0x8CA9, resolved);
        GL_BlitFramebuffer(0, 0, 64, 64, 0, 0, 64, 64, 0x4000, 0x2600);
        error = GL_GetError();
        GL_BindFramebuffer(0x8D40, resolved);
        GL_ReadPixels(32, 32, 1, 1, 0x1908, 0x1401, px);
        if (error || px[0] < 190 || px[0] > 192 || px[1] < 127 || px[1] > 129 || px[2] < 63 || px[2] > 65 || px[3] != 255)
            return FAIL(bug, "%s: multisampled uniform-block draw resolved: GL error %#x, pixel %u %u %u %u, want 191 128 64 255",
                        renderer, error, px[0], px[1], px[2], px[3]);
        return PASS(bug, "%s: WebKit's ANGLE resolves a multisampled clear and a uniform-block draw", renderer);
    }
}
