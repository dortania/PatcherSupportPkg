// s64-firefox-angle-display: Firefox's own ANGLE must get a display on these Macs; it refused them (no WebGL).
// Fix: MetalOldCompat item 11. Needs Firefox (/Applications/Firefox.app or S64_FIREFOX_APP), else SKIP.
// Checks: a 4x MSAA clear and uniform-block draw, resolved and read back.
#import "repro.h"
#include <dlfcn.h>

typedef void *P;
typedef int32_t I;
typedef uint32_t U;
static void *angle, *gles;
#define F(ret, name, ...) static ret (*name)(__VA_ARGS__);
F(P, eglGetPlatformDisplayEXT, U, P, const I *) F(U, eglInitialize, P, I *, I *) F(U, eglChooseConfig, P, const I *, P *, I, I *)
F(P, eglCreatePbufferSurface, P, P, const I *) F(P, eglCreateContext, P, P, P, const I *) F(U, eglMakeCurrent, P, P, P, P)
F(U, eglBindAPI, U) F(void, glClearColor, float, float, float, float) F(void, glClear, U) F(void, glReadPixels, I, I, I, I, U, U, void *)
F(U, glGetError, void) F(U, glCreateShader, U) F(void, glShaderSource, U, I, const char *const *, const I *) F(void, glCompileShader, U)
F(U, glCreateProgram, void) F(void, glAttachShader, U, U) F(void, glLinkProgram, U) F(void, glGetProgramiv, U, U, I *) F(void, glUseProgram, U)
F(void, glGenBuffers, I, U *) F(void, glBindBuffer, U, U) F(void, glBufferData, U, intptr_t, const void *, U)
F(U, glGetUniformBlockIndex, U, const char *) F(void, glUniformBlockBinding, U, U, U) F(void, glBindBufferBase, U, U, U)
F(void, glViewport, I, I, I, I) F(void, glDrawArrays, U, I, I) F(const char *, glGetString, U) F(void, glGenFramebuffers, I, U *)
F(void, glBindFramebuffer, U, U) F(void, glGenRenderbuffers, I, U *) F(void, glBindRenderbuffer, U, U)
F(void, glRenderbufferStorageMultisample, U, I, U, I, I) F(void, glFramebufferRenderbuffer, U, U, U, U) F(void, glGenTextures, I, U *)
F(void, glBindTexture, U, U) F(void, glTexStorage2D, U, I, U, I, I) F(void, glFramebufferTexture2D, U, U, U, U, I)
F(void, glBlitFramebuffer, I, I, I, I, I, I, I, I, U, U)
#define L(name) if (!(name = dlsym(#name[0] == 'g' ? gles : angle, #name))) return SKIP(bug, "Firefox's ANGLE has no " #name);

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s64-firefox-angle-display";
        MTLCreateSystemDefaultDevice();  // the driver's classes get patched with the first device
        // libGLESv2 loads @rpath/libmozglue.dylib, which is next to it: run with DYLD_FALLBACK_LIBRARY_PATH set to Firefox's MacOS
        // folder if this dlopen fails (verify.sh does)
        const char *app = getenv("S64_FIREFOX_APP") ?: "/Applications/Firefox.app";  // another Firefox: S64_FIREFOX_APP=/path/Firefox.app
        char path[1024];
        snprintf(path, sizeof path, "%s/Contents/MacOS/libGLESv2.dylib", app);
        gles = dlopen(path, RTLD_NOW);
        snprintf(path, sizeof path, "%s/Contents/MacOS/libEGL.dylib", app);
        angle = gles ? dlopen(path, RTLD_NOW) : NULL;
        if (!angle) return SKIP(bug, "no Firefox ANGLE: %s", dlerror());
        L(eglGetPlatformDisplayEXT) L(eglInitialize) L(eglChooseConfig) L(eglCreatePbufferSurface) L(eglCreateContext) L(eglMakeCurrent)
        L(eglBindAPI) L(glClearColor) L(glClear) L(glReadPixels) L(glGetError) L(glCreateShader) L(glShaderSource) L(glCompileShader)
        L(glCreateProgram) L(glAttachShader) L(glLinkProgram) L(glGetProgramiv) L(glUseProgram) L(glGenBuffers) L(glBindBuffer)
        L(glBufferData) L(glGetUniformBlockIndex) L(glUniformBlockBinding) L(glBindBufferBase) L(glViewport) L(glDrawArrays) L(glGetString)
        L(glGenFramebuffers) L(glBindFramebuffer) L(glGenRenderbuffers) L(glBindRenderbuffer) L(glRenderbufferStorageMultisample)
        L(glFramebufferRenderbuffer) L(glGenTextures) L(glBindTexture) L(glTexStorage2D) L(glFramebufferTexture2D) L(glBlitFramebuffer)
        const I displayAttributes[] = {0x3203, 0x3489, 0x3038};  // EGL_PLATFORM_ANGLE_TYPE_ANGLE: METAL
        P display = eglGetPlatformDisplayEXT(0x3202, 0, displayAttributes);
        I major, minor, configs;
        if (!display || !eglInitialize(display, &major, &minor)) return FAIL(bug, "Firefox's ANGLE: the Metal display didn't initialize (FEATURE_FAILURE_NO_DISPLAY)");
        const I configAttributes[] = {0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038};
        P config;
        eglChooseConfig(display, configAttributes, &config, 1, &configs);
        eglBindAPI(0x30A0);
        const I surfaceAttributes[] = {0x3057, 64, 0x3056, 64, 0x3038};
        P surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
        const I contextAttributes[] = {0x3098, 3, 0x33AC, 1, 0x3038};  // ES 3, WebGL compatibility, as WebKit asks
        P context = eglCreateContext(display, config, 0, contextAttributes);
        if (!context || !eglMakeCurrent(display, surface, surface, context)) return FAIL(bug, "no ANGLE ES 3 context");
        const char *renderer = glGetString(0x1F01);
        U multisampled, buffers[2], resolved, texture;
        glGenFramebuffers(1, &multisampled);
        glGenRenderbuffers(2, buffers);
        glGenFramebuffers(1, &resolved);
        glGenTextures(1, &texture);
        glBindRenderbuffer(0x8D41, buffers[0]);
        glRenderbufferStorageMultisample(0x8D41, 4, 0x8058, 64, 64);  // RGBA8
        glBindRenderbuffer(0x8D41, buffers[1]);
        glRenderbufferStorageMultisample(0x8D41, 4, 0x88F0, 64, 64);  // DEPTH24_STENCIL8
        glBindFramebuffer(0x8D40, multisampled);
        glFramebufferRenderbuffer(0x8D40, 0x8CE0, 0x8D41, buffers[0]);
        glFramebufferRenderbuffer(0x8D40, 0x821A, 0x8D41, buffers[1]);
        glBindTexture(0x0DE1, texture);
        glTexStorage2D(0x0DE1, 1, 0x8058, 64, 64);
        glBindFramebuffer(0x8D40, resolved);
        glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, texture, 0);
        uint8_t px[4];
        // a clear, resolved
        glBindFramebuffer(0x8D40, multisampled);
        glClearColor(0, 1, 0, 1);
        glClear(0x4000 | 0x100);
        glBindFramebuffer(0x8CA8, multisampled);
        glBindFramebuffer(0x8CA9, resolved);
        glBlitFramebuffer(0, 0, 64, 64, 0, 0, 64, 64, 0x4000, 0x2600);
        U error = glGetError();
        glBindFramebuffer(0x8D40, resolved);
        glReadPixels(0, 0, 1, 1, 0x1908, 0x1401, px);
        if (error || px[0] != 0 || px[1] != 255 || px[2] != 0 || px[3] != 255)
            return FAIL(bug, "%s: multisampled clear resolved by glBlitFramebuffer: GL error %#x, pixel %u %u %u %u, want 0 255 0 255",
                        renderer, error, px[0], px[1], px[2], px[3]);
        // a draw reading a uniform block, resolved
        const char *vs = "#version 300 es\nvoid main(){vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3));gl_Position=vec4(p[gl_VertexID],0,1);}";
        const char *fs = "#version 300 es\nprecision highp float; layout(std140) uniform U{vec4 color; vec4 color2;}; out vec4 o;"
                         " void main(){o=color+color2;}";
        U program = glCreateProgram(), v = glCreateShader(0x8B31), f = glCreateShader(0x8B30);
        glShaderSource(v, 1, &vs, 0);
        glShaderSource(f, 1, &fs, 0);
        glCompileShader(v);
        glCompileShader(f);
        glAttachShader(program, v);
        glAttachShader(program, f);
        glLinkProgram(program);
        I linked = 0;
        glGetProgramiv(program, 0x8B82, &linked);
        if (!linked) return FAIL(bug, "%s: the uniform-block program didn't link", renderer);
        glUseProgram(program);
        U block;
        glGenBuffers(1, &block);
        glBindBuffer(0x8A11, block);
        const float values[8] = {0.25f, 0.5f, 0, 1, 0.5f, 0, 0.25f, 0};
        glBufferData(0x8A11, sizeof values, values, 0x88E4);
        glUniformBlockBinding(program, glGetUniformBlockIndex(program, "U"), 0);
        glBindBufferBase(0x8A11, 0, block);
        glBindFramebuffer(0x8D40, multisampled);
        glViewport(0, 0, 64, 64);
        glClearColor(0, 0, 0, 0);
        glClear(0x4000 | 0x100);
        glDrawArrays(4, 0, 3);
        glBindFramebuffer(0x8CA8, multisampled);
        glBindFramebuffer(0x8CA9, resolved);
        glBlitFramebuffer(0, 0, 64, 64, 0, 0, 64, 64, 0x4000, 0x2600);
        error = glGetError();
        glBindFramebuffer(0x8D40, resolved);
        glReadPixels(32, 32, 1, 1, 0x1908, 0x1401, px);
        if (error || px[0] < 190 || px[0] > 192 || px[1] < 127 || px[1] > 129 || px[2] < 63 || px[2] > 65 || px[3] != 255)
            return FAIL(bug, "%s: multisampled uniform-block draw resolved: GL error %#x, pixel %u %u %u %u, want 191 128 64 255",
                        renderer, error, px[0], px[1], px[2], px[3]);
        return PASS(bug, "%s: Firefox's ANGLE starts, and resolves a multisampled clear and a uniform-block draw", renderer);
    }
}
