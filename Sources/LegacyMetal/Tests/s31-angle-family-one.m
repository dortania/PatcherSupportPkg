// s31-angle-family-one (MetalOldCompat item 11): WebKit's ANGLE on a Mac whose only GPU is a family-1 one (Haswell /
// Ivy Bridge iGPU). ANGLE refuses such a GPU (IsMetalRendererAvailable and DisplayMtl's requireGpuFamily2), so Safari's
// WebGL contexts are lost and Chrome runs without GPU acceleration. With the fix ANGLE gets the GPU as family 2 and its
// fallbacks for the three family-2 features the 12.x Intel driver lacks. This program loads WebKit's libANGLE-shared
// into itself (the shim treats calls from it as WebKit's), creates an OpenGL ES 3 context on a pbuffer and checks:
//   - a LUMINANCE_ALPHA texture samples as (L, L, L, A): with ANGLE's texture swizzle feature on, the driver returns nil
//     for the swizzled view ANGLE samples through
//   - stencil blitted out of a 4x multisampled framebuffer arrives: with ANGLE's stencil auto-resolve on, the driver
//     writes nothing
// Stock OCLP: FAIL (eglInitialize fails). Fixed: PASS. SKIP where a family-2 GPU exists (ANGLE runs there) or WebKit's
// ANGLE isn't found.
#import "repro.h"
#include <dlfcn.h>

typedef int32_t EGLint;
typedef unsigned int EGLenum, EGLBoolean, GLenum, GLuint, GLbitfield;
typedef int GLint, GLsizei;
typedef intptr_t EGLAttrib;
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;

enum {
    EGL_NONE = 0x3038, EGL_PLATFORM_ANGLE_ANGLE = 0x3202, EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203,
    EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE = 0x3489, EGL_SURFACE_TYPE = 0x3033, EGL_PBUFFER_BIT = 0x0001,
    EGL_RENDERABLE_TYPE = 0x3040, EGL_OPENGL_ES3_BIT = 0x0040, EGL_RED_SIZE = 0x3024, EGL_GREEN_SIZE = 0x3023,
    EGL_BLUE_SIZE = 0x3022, EGL_ALPHA_SIZE = 0x3021, EGL_WIDTH = 0x3057, EGL_HEIGHT = 0x3056,
    EGL_CONTEXT_CLIENT_VERSION = 0x3098,
    GL_RENDERER = 0x1F01, GL_TEXTURE_2D = 0x0DE1, GL_LUMINANCE_ALPHA = 0x190A, GL_UNSIGNED_BYTE = 0x1401,
    GL_TEXTURE_MIN_FILTER = 0x2801, GL_TEXTURE_MAG_FILTER = 0x2800, GL_NEAREST = 0x2600, GL_VERTEX_SHADER = 0x8B31,
    GL_FRAGMENT_SHADER = 0x8B30, GL_LINK_STATUS = 0x8B82, GL_ARRAY_BUFFER = 0x8892, GL_STATIC_DRAW = 0x88E4,
    GL_FLOAT = 0x1406, GL_TRIANGLES = 0x0004, GL_FRAMEBUFFER = 0x8D40, GL_READ_FRAMEBUFFER = 0x8CA8,
    GL_DRAW_FRAMEBUFFER = 0x8CA9, GL_RENDERBUFFER = 0x8D41, GL_RGBA8 = 0x8058, GL_DEPTH24_STENCIL8 = 0x88F0,
    GL_COLOR_ATTACHMENT0 = 0x8CE0, GL_DEPTH_STENCIL_ATTACHMENT = 0x821A, GL_FRAMEBUFFER_COMPLETE = 0x8CD5,
    GL_COLOR_BUFFER_BIT = 0x4000, GL_DEPTH_BUFFER_BIT = 0x0100, GL_STENCIL_BUFFER_BIT = 0x0400, GL_STENCIL_TEST = 0x0B90,
    GL_EQUAL = 0x0202, GL_RGBA = 0x1908,
};

static const char *const kANGLEPaths[] = {
    "/System/Cryptexes/App/System/Library/StagedFrameworks/Safari/libANGLE-shared.dylib",  // Safari's own (Sequoia)
    "/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/libANGLE-shared.dylib",
    "/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/Frameworks/libANGLE-shared.dylib",
};

#define FN(ret, name, ...) static ret (*name)(__VA_ARGS__)
FN(EGLDisplay, eglGetPlatformDisplay, EGLenum, void *, const EGLAttrib *);
FN(EGLBoolean, eglInitialize, EGLDisplay, EGLint *, EGLint *);
FN(EGLint, eglGetError, void);
FN(EGLBoolean, eglChooseConfig, EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
FN(EGLSurface, eglCreatePbufferSurface, EGLDisplay, EGLConfig, const EGLint *);
FN(EGLContext, eglCreateContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
FN(EGLBoolean, eglMakeCurrent, EGLDisplay, EGLSurface, EGLSurface, EGLContext);
FN(const char *, glGetString, GLenum);
FN(GLenum, glGetError, void);
FN(void, glViewport, GLint, GLint, GLsizei, GLsizei);
FN(void, glClearColor, float, float, float, float);
FN(void, glClearStencil, GLint);
FN(void, glClear, GLbitfield);
FN(void, glReadPixels, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
FN(GLuint, glCreateShader, GLenum);
FN(void, glShaderSource, GLuint, GLsizei, const char *const *, const GLint *);
FN(void, glCompileShader, GLuint);
FN(GLuint, glCreateProgram, void);
FN(void, glAttachShader, GLuint, GLuint);
FN(void, glBindAttribLocation, GLuint, GLuint, const char *);
FN(void, glLinkProgram, GLuint);
FN(void, glGetProgramiv, GLuint, GLenum, GLint *);
FN(void, glUseProgram, GLuint);
FN(void, glGenBuffers, GLsizei, GLuint *);
FN(void, glBindBuffer, GLenum, GLuint);
FN(void, glBufferData, GLenum, intptr_t, const void *, GLenum);
FN(void, glVertexAttribPointer, GLuint, GLint, GLenum, unsigned char, GLsizei, const void *);
FN(void, glEnableVertexAttribArray, GLuint);
FN(void, glDrawArrays, GLenum, GLint, GLsizei);
FN(void, glGenTextures, GLsizei, GLuint *);
FN(void, glBindTexture, GLenum, GLuint);
FN(void, glTexParameteri, GLenum, GLenum, GLint);
FN(void, glTexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
FN(void, glGenFramebuffers, GLsizei, GLuint *);
FN(void, glBindFramebuffer, GLenum, GLuint);
FN(GLenum, glCheckFramebufferStatus, GLenum);
FN(void, glFramebufferRenderbuffer, GLenum, GLenum, GLenum, GLuint);
FN(void, glGenRenderbuffers, GLsizei, GLuint *);
FN(void, glBindRenderbuffer, GLenum, GLuint);
FN(void, glRenderbufferStorageMultisample, GLenum, GLsizei, GLenum, GLsizei, GLsizei);
FN(void, glBlitFramebuffer, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
FN(void, glEnable, GLenum);
FN(void, glDisable, GLenum);
FN(void, glStencilFunc, GLenum, GLint, GLuint);

static BOOL load(void *lib) {
#define LOAD(name, prefix, symbol) if (!(*(void **)&name = dlsym(lib, prefix symbol))) return NO;
    LOAD(eglGetPlatformDisplay, "EGL_", "GetPlatformDisplay") LOAD(eglInitialize, "EGL_", "Initialize")
    LOAD(eglGetError, "EGL_", "GetError") LOAD(eglChooseConfig, "EGL_", "ChooseConfig")
    LOAD(eglCreatePbufferSurface, "EGL_", "CreatePbufferSurface") LOAD(eglCreateContext, "EGL_", "CreateContext")
    LOAD(eglMakeCurrent, "EGL_", "MakeCurrent")
    LOAD(glGetString, "GL_", "GetString") LOAD(glGetError, "GL_", "GetError") LOAD(glViewport, "GL_", "Viewport")
    LOAD(glClearColor, "GL_", "ClearColor") LOAD(glClearStencil, "GL_", "ClearStencil") LOAD(glClear, "GL_", "Clear")
    LOAD(glReadPixels, "GL_", "ReadPixels") LOAD(glCreateShader, "GL_", "CreateShader")
    LOAD(glShaderSource, "GL_", "ShaderSource") LOAD(glCompileShader, "GL_", "CompileShader")
    LOAD(glCreateProgram, "GL_", "CreateProgram") LOAD(glAttachShader, "GL_", "AttachShader")
    LOAD(glBindAttribLocation, "GL_", "BindAttribLocation") LOAD(glLinkProgram, "GL_", "LinkProgram")
    LOAD(glGetProgramiv, "GL_", "GetProgramiv") LOAD(glUseProgram, "GL_", "UseProgram")
    LOAD(glGenBuffers, "GL_", "GenBuffers") LOAD(glBindBuffer, "GL_", "BindBuffer") LOAD(glBufferData, "GL_", "BufferData")
    LOAD(glVertexAttribPointer, "GL_", "VertexAttribPointer") LOAD(glEnableVertexAttribArray, "GL_", "EnableVertexAttribArray")
    LOAD(glDrawArrays, "GL_", "DrawArrays") LOAD(glGenTextures, "GL_", "GenTextures") LOAD(glBindTexture, "GL_", "BindTexture")
    LOAD(glTexParameteri, "GL_", "TexParameteri") LOAD(glTexImage2D, "GL_", "TexImage2D")
    LOAD(glGenFramebuffers, "GL_", "GenFramebuffers") LOAD(glBindFramebuffer, "GL_", "BindFramebuffer")
    LOAD(glCheckFramebufferStatus, "GL_", "CheckFramebufferStatus")
    LOAD(glFramebufferRenderbuffer, "GL_", "FramebufferRenderbuffer") LOAD(glGenRenderbuffers, "GL_", "GenRenderbuffers")
    LOAD(glBindRenderbuffer, "GL_", "BindRenderbuffer")
    LOAD(glRenderbufferStorageMultisample, "GL_", "RenderbufferStorageMultisample")
    LOAD(glBlitFramebuffer, "GL_", "BlitFramebuffer") LOAD(glEnable, "GL_", "Enable") LOAD(glDisable, "GL_", "Disable")
    LOAD(glStencilFunc, "GL_", "StencilFunc")
    return YES;
#undef LOAD
}

static GLuint program(const char *fragment) {
    static const char *vertex = "#version 300 es\nin vec2 p; out vec2 uv;\n"
                                "void main() { uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }\n";
    GLuint vs = glCreateShader(GL_VERTEX_SHADER), fs = glCreateShader(GL_FRAGMENT_SHADER), prog = glCreateProgram();
    glShaderSource(vs, 1, &vertex, NULL);
    glShaderSource(fs, 1, &fragment, NULL);
    glCompileShader(vs);
    glCompileShader(fs);
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "p");
    glLinkProgram(prog);
    GLint linked = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    return linked ? prog : 0;
}

static GLuint renderbufferFramebuffer(GLsizei samples) {  // 4x4 RGBA8 + DEPTH24_STENCIL8
    GLuint fb, rb[2];
    glGenFramebuffers(1, &fb);
    glGenRenderbuffers(2, rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb[0]);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8, 4, 4);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb[0]);
    glBindRenderbuffer(GL_RENDERBUFFER, rb[1]);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_DEPTH24_STENCIL8, 4, 4);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rb[1]);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE ? fb : 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s31-angle-family-one";
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return SKIP(bug, "no Metal device");
        for (id<MTLDevice> d in MTLCopyAllDevices())
            if ([d supportsFamily:MTLGPUFamilyMac2]) return SKIP(bug, "%s is family 2: ANGLE runs there", d.name.UTF8String);
        void *lib = NULL;
        for (size_t i = 0; i < sizeof kANGLEPaths / sizeof *kANGLEPaths && !lib; i++) lib = dlopen(kANGLEPaths[i], RTLD_NOW | RTLD_LOCAL);
        if (!lib) return SKIP(bug, "WebKit's libANGLE-shared.dylib not found");
        if (!load(lib)) return SKIP(bug, "libANGLE-shared.dylib lacks an entry point this test uses");

        const EGLAttrib displayAttribs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
        EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, displayAttribs);
        EGLint major = 0, minor = 0;
        if (!display || !eglInitialize(display, &major, &minor))
            return FAIL(bug, "%s: ANGLE's Metal display doesn't initialize (EGL error 0x%x): no WebGL in Safari, no GPU in Chrome",
                        dev.name.UTF8String, eglGetError());
        const EGLint configAttribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_RED_SIZE, 8,
                                        EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
        EGLConfig config = NULL;
        EGLint count = 0;
        const EGLint surfaceAttribs[] = {EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE}, contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        EGLSurface surface = eglChooseConfig(display, configAttribs, &config, 1, &count) && count ? eglCreatePbufferSurface(display, config, surfaceAttribs) : NULL;
        EGLContext context = surface ? eglCreateContext(display, config, NULL, contextAttribs) : NULL;
        if (!context || !eglMakeCurrent(display, surface, surface, context))
            return FAIL(bug, "%s: no OpenGL ES 3 context (EGL error 0x%x)", dev.name.UTF8String, eglGetError());
        const char *renderer = glGetString(GL_RENDERER);

        static const float quad[] = {-1, -1, 3, -1, -1, 3};
        GLuint vbo;
        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, NULL);
        glEnableVertexAttribArray(0);
        glViewport(0, 0, 4, 4);

        // LUMINANCE_ALPHA (200, 100) sampled into the pbuffer
        GLuint sampling = program("#version 300 es\nprecision mediump float; uniform sampler2D t; in vec2 uv; out vec4 o;\n"
                                  "void main() { o = texture(t, uv); }\n");
        GLuint solid = program("#version 300 es\nprecision mediump float; out vec4 o; void main() { o = vec4(0.0, 1.0, 0.0, 1.0); }\n");
        if (!sampling || !solid) return FAIL(bug, "%s: shader programs don't link", dev.name.UTF8String);
        unsigned char texels[4 * 4 * 2];
        for (size_t i = 0; i < sizeof texels; i += 2) texels[i] = 200, texels[i + 1] = 100;
        GLuint tex;
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE_ALPHA, 4, 4, 0, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, texels);
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        glUseProgram(sampling);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        unsigned char px[4] = {0};
        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        GLenum error = glGetError();
        if (error || abs(px[0] - 200) > 2 || abs(px[1] - 200) > 2 || abs(px[2] - 200) > 2 || abs(px[3] - 100) > 2)
            return FAIL(bug, "%s: LUMINANCE_ALPHA (200, 100) sampled as %d %d %d %d (GL error 0x%x), want 200 200 200 100",
                        dev.name.UTF8String, px[0], px[1], px[2], px[3], error);

        // stencil 0x5A blitted out of a 4x multisampled framebuffer, then used for a stencil test
        GLuint msaa = renderbufferFramebuffer(4), single = renderbufferFramebuffer(0);
        if (!msaa || !single) return FAIL(bug, "%s: framebuffers incomplete", dev.name.UTF8String);
        glBindFramebuffer(GL_FRAMEBUFFER, msaa);
        glClearStencil(0x5A);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        glBindFramebuffer(GL_FRAMEBUFFER, single);
        glClearStencil(0);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, msaa);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, single);
        glBlitFramebuffer(0, 0, 4, 4, 0, 0, 4, 4, GL_STENCIL_BUFFER_BIT, GL_NEAREST);
        GLenum blitError = glGetError();
        glBindFramebuffer(GL_FRAMEBUFFER, single);
        glEnable(GL_STENCIL_TEST);
        glStencilFunc(GL_EQUAL, 0x5A, 0xFF);
        glUseProgram(solid);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glDisable(GL_STENCIL_TEST);
        memset(px, 0, sizeof px);
        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        if (blitError || px[1] != 255)
            return FAIL(bug, "%s: stencil 0x5A blitted out of a 4x MSAA framebuffer: %s (GL error 0x%x)", dev.name.UTF8String,
                        px[1] == 255 ? "passes" : "lost", blitError);
        return PASS(bug, "%s: ANGLE runs (%s, OpenGL ES 3); luminance-alpha sampling and MSAA stencil blits right",
                    dev.name.UTF8String, renderer ? renderer : "?");
    }
}
