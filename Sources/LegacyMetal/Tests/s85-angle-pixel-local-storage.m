// s85-angle-pixel-local-storage (shim items 11 and 73): Chrome 158 offers WebGL's WEBGL_shader_pixel_local_storage, which
// ANGLE builds on its GL_ANGLE_shader_pixel_local_storage. On these GPUs ANGLE's Metal backend keeps the planes in read_write
// textures, so a draw that only uses pixel local storage has no attachment at all. Item 11 presents family-1 GPUs to ANGLE
// as family 2, and used to switch ANGLE's allowRenderpassWithoutAttachment off for them (family 1 couldn't make such
// pipelines); with it off ANGLE refuses the pipeline ("Render pipeline requires at least one render target for this
// device"), loses the context, and Chrome running its GPU code in process went down (WebGL conformance
// webgl-shader-pixel-local-storage). Item 73 gives such pipelines and passes a dummy target on family-1 GPUs, so item 11
// now leaves that feature to ANGLE. This drives WebKit's ANGLE (the same ANGLE code; Safari's caller) through its EGL_/GL_
// entry points: one r32ui plane on a framebuffer with no other attachment, loaded as zero, two draws that each add 7
// (with a barrier between them, as the extension asks without raster order groups), stored and read back: 14 everywhere.
// FAIL with item 11's old list (MTLSHIM_NO_ATTACHMENTS=0 restores it). SKIP without WebKit's ANGLE or the extension.
// Runs on the GPU ANGLE picks (the result line names the renderer); an Intel argument on a dual-GPU Mac picks the iGPU.
#import "repro.h"
#include <dlfcn.h>
#include <string.h>

typedef void *P;
typedef int32_t I;
typedef uint32_t U;
static void *angle;
#define F(ret, name, ...) static ret (*name)(__VA_ARGS__);
F(P, EGL_GetPlatformDisplayEXT, U, P, const I *) F(U, EGL_Initialize, P, I *, I *) F(U, EGL_ChooseConfig, P, const I *, P *, I, I *)
F(P, EGL_CreatePbufferSurface, P, P, const I *) F(P, EGL_CreateContext, P, P, P, const I *) F(U, EGL_MakeCurrent, P, P, P, P)
F(U, EGL_BindAPI, U) F(void, GL_ReadPixels, I, I, I, I, U, U, void *) F(U, GL_GetError, void) F(U, GL_CreateShader, U)
F(void, GL_ShaderSource, U, I, const char *const *, const I *) F(void, GL_CompileShader, U) F(void, GL_GetShaderiv, U, U, I *)
F(void, GL_GetShaderInfoLog, U, I, I *, char *) F(U, GL_CreateProgram, void) F(void, GL_AttachShader, U, U) F(void, GL_LinkProgram, U)
F(void, GL_GetProgramiv, U, U, I *) F(void, GL_UseProgram, U) F(void, GL_Viewport, I, I, I, I) F(void, GL_DrawArrays, U, I, I)
F(const char *, GL_GetString, U) F(void, GL_GenFramebuffers, I, U *) F(void, GL_BindFramebuffer, U, U) F(void, GL_GenTextures, I, U *)
F(void, GL_BindTexture, U, U) F(void, GL_TexStorage2D, U, I, U, I, I) F(void, GL_FramebufferTexture2D, U, U, U, U, I) F(void, GL_Disable, U)
F(void, GL_FramebufferTexturePixelLocalStorageANGLE, I, U, I, I, U) F(void, GL_BeginPixelLocalStorageANGLE, I, const U *)
F(void, GL_EndPixelLocalStorageANGLE, I, const U *) F(void, GL_PixelLocalStorageBarrierANGLE, void)
F(void, GL_DebugMessageCallbackKHR, void (*)(U, U, U, U, I, const char *, const void *), const void *) F(void, GL_Enable, U)
#define L(name) if (!(name = dlsym(angle, #name))) return SKIP(bug, "WebKit's ANGLE has no " #name);

enum { kSize = 32 };

static void debugMessage(U source, U type, U id, U severity, I length, const char *message, const void *user) {
    fprintf(stderr, "[ANGLE] %s\n", message);
}
static U step(const char *what) {  // S85_VERBOSE=1: the GL error after each call, and ANGLE's own messages
    U error = getenv("S85_VERBOSE") ? GL_GetError() : 0;
    if (error) fprintf(stderr, "s85: %s: GL error %#x\n", what, error);
    return error;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s85-angle-pixel-local-storage";
        // WebKit's ANGLE takes the GPU item 11 gives it (the family-2 one on a dual-GPU Mac); asked for the Intel GPU, the
        // test makes ANGLE's callers see only the iGPU (MTLSHIM_TEST_IGPU_ONLY), so the family-1 Intel path runs there too
        if (argc > 1 && strcasestr(argv[1], "intel") && MTLCopyAllDevices().count > 1) setenv("MTLSHIM_TEST_IGPU_ONLY", "1", 0);
        MTLCreateSystemDefaultDevice();  // as WebCore does in Safari's GPU process before ANGLE starts
        angle = dlopen("/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/"
                       "libANGLE-shared.dylib", RTLD_NOW);
        if (!angle) return SKIP(bug, "no WebKit ANGLE (libANGLE-shared.dylib)");
        L(EGL_GetPlatformDisplayEXT) L(EGL_Initialize) L(EGL_ChooseConfig) L(EGL_CreatePbufferSurface) L(EGL_CreateContext) L(EGL_MakeCurrent)
        L(EGL_BindAPI) L(GL_ReadPixels) L(GL_GetError) L(GL_CreateShader) L(GL_ShaderSource) L(GL_CompileShader) L(GL_GetShaderiv)
        L(GL_GetShaderInfoLog) L(GL_CreateProgram) L(GL_AttachShader) L(GL_LinkProgram) L(GL_GetProgramiv) L(GL_UseProgram) L(GL_Viewport)
        L(GL_DrawArrays) L(GL_GetString) L(GL_GenFramebuffers) L(GL_BindFramebuffer) L(GL_GenTextures) L(GL_BindTexture) L(GL_TexStorage2D)
        L(GL_FramebufferTexture2D) L(GL_Disable) L(GL_FramebufferTexturePixelLocalStorageANGLE) L(GL_BeginPixelLocalStorageANGLE)
        L(GL_EndPixelLocalStorageANGLE) L(GL_PixelLocalStorageBarrierANGLE)
        const I displayAttributes[] = {0x3203, 0x3489, 0x3038};  // EGL_PLATFORM_ANGLE_TYPE_ANGLE: METAL
        P display = EGL_GetPlatformDisplayEXT(0x3202, 0, displayAttributes);
        I major, minor, configs;
        if (!display || !EGL_Initialize(display, &major, &minor)) return FAIL(bug, "ANGLE's Metal display didn't initialize");
        const I configAttributes[] = {0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038};
        P config;
        EGL_ChooseConfig(display, configAttributes, &config, 1, &configs);
        EGL_BindAPI(0x30A0);
        const I surfaceAttributes[] = {0x3057, kSize, 0x3056, kSize, 0x3038};
        P surface = EGL_CreatePbufferSurface(display, config, surfaceAttributes);
        const I contextAttributes[] = {0x3098, 3, 0x3038};  // ES 3, every extension on (no WebGL compatibility: nothing to request)
        P context = EGL_CreateContext(display, config, 0, contextAttributes);
        if (!context || !EGL_MakeCurrent(display, surface, surface, context)) return FAIL(bug, "no ANGLE ES 3 context");
        if (getenv("S85_VERBOSE") && (GL_DebugMessageCallbackKHR = dlsym(angle, "GL_DebugMessageCallbackKHR")) && (GL_Enable = dlsym(angle, "GL_Enable"))) {
            GL_Enable(0x92E0);  // DEBUG_OUTPUT
            GL_DebugMessageCallbackKHR(debugMessage, NULL);
        }
        const char *renderer = GL_GetString(0x1F01), *extensions = GL_GetString(0x1F03);
        if (!extensions || !strstr(extensions, "GL_ANGLE_shader_pixel_local_storage "))
            return SKIP(bug, "%s: WebKit's ANGLE doesn't offer GL_ANGLE_shader_pixel_local_storage here", renderer);

        const char *vs = "#version 300 es\nvoid main(){vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3));gl_Position=vec4(p[gl_VertexID],0,1);}";
        const char *fs = "#version 300 es\n#extension GL_ANGLE_shader_pixel_local_storage : require\nprecision highp float;\n"
                         "layout(binding=0, r32ui) uniform highp upixelLocalANGLE pls;\n"
                         "void main(){ uint v = pixelLocalLoadANGLE(pls).x; pixelLocalStoreANGLE(pls, uvec4(v + 7u, 0u, 0u, 0u)); }";
        U program = GL_CreateProgram(), v = GL_CreateShader(0x8B31), f = GL_CreateShader(0x8B30);
        GL_ShaderSource(v, 1, &vs, 0);
        GL_ShaderSource(f, 1, &fs, 0);
        GL_CompileShader(v);
        GL_CompileShader(f);
        I compiled = 0;
        GL_GetShaderiv(f, 0x8B81, &compiled);
        if (!compiled) {
            char log[512] = "";
            GL_GetShaderInfoLog(f, sizeof log, NULL, log);
            return FAIL(bug, "%s: the pixel local storage shader didn't compile: %s", renderer, log);
        }
        GL_AttachShader(program, v);
        GL_AttachShader(program, f);
        GL_LinkProgram(program);
        I linked = 0;
        GL_GetProgramiv(program, 0x8B82, &linked);
        if (!linked) return FAIL(bug, "%s: the pixel local storage program didn't link", renderer);

        U plane, framebuffer, readback;
        GL_GenTextures(1, &plane);
        GL_BindTexture(0x0DE1, plane);
        GL_TexStorage2D(0x0DE1, 1, 0x8236, kSize, kSize);  // R32UI
        GL_GenFramebuffers(1, &framebuffer);
        GL_BindFramebuffer(0x8D40, framebuffer);  // no attachment but the plane
        GL_FramebufferTexturePixelLocalStorageANGLE(0, plane, 0, 0, 0);  // usage 0 (builds without the argument ignore it)
        U error = GL_GetError();
        if (error) return FAIL(bug, "%s: glFramebufferTexturePixelLocalStorageANGLE: GL error %#x", renderer, error);
        GL_Viewport(0, 0, kSize, kSize);
        GL_Disable(0x0BD0);  // GL_DITHER: pixel local storage may not begin with it on (WebGL turns it off too)
        GL_UseProgram(program);
        // GL_LOAD_OP_ZERO_ANGLE / GL_STORE_OP_STORE_ANGLE; ANGLE builds from before March 2025 (MAX_COLOR_ATTACHMENTS_WITH_
        // ACTIVE_PIXEL_LOCAL_STORAGE_ANGLE was cut then) number them one higher: WebKit's on Sequoia is one
        U load = 0x96E3, store = 0x96E6;
        GL_BeginPixelLocalStorageANGLE(1, &load);
        if (GL_GetError() == 0x0500) {  // INVALID_ENUM
            load = 0x96E4, store = 0x96E7;
            GL_BeginPixelLocalStorageANGLE(1, &load);
        }
        step("glBeginPixelLocalStorageANGLE");
        GL_DrawArrays(0x0004, 0, 3);
        step("first draw");
        GL_PixelLocalStorageBarrierANGLE();
        step("glPixelLocalStorageBarrierANGLE");
        GL_DrawArrays(0x0004, 0, 3);
        step("second draw");
        GL_EndPixelLocalStorageANGLE(1, &store);
        step("glEndPixelLocalStorageANGLE");
        error = GL_GetError();

        GL_GenFramebuffers(1, &readback);
        GL_BindFramebuffer(0x8D40, readback);
        GL_FramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, plane, 0);
        static uint32_t px[kSize * kSize * 4];
        memset(px, 0xff, sizeof px);
        GL_ReadPixels(0, 0, kSize, kSize, 0x8D99, 0x1405, px);  // RGBA_INTEGER, UNSIGNED_INT
        U readError = GL_GetError();
        int wrong = 0, first = -1;
        for (int i = 0; i < kSize * kSize; i++)
            if (px[i * 4] != 14 && wrong++ == 0) first = i;
        if (error || readError || wrong)
            return FAIL(bug, "%s: a pixel local storage plane with no attachment, zeroed and added to by two draws: GL error %#x (read %#x), "
                        "%d of %d pixels not 14 (first: %u at %d)", renderer, error, readError, wrong, kSize * kSize, first >= 0 ? px[first * 4] : 0, first);
        return PASS(bug, "%s: WebKit's ANGLE draws into a pixel local storage plane with no attachment (two draws: 14 everywhere)", renderer);
    }
}
