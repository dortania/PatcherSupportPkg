// s69-safari-webgl-arb-sync (MetalOldCompat item 11): Safari 18's WebKit makes every WebGL context (WebGL 1 and 2) require
// GL_ARB_sync (GraphicsContextGLCocoa::platformInitializeExtensions: "Sync objects are used to throttle display on Metal
// implementations"), and WebKit's ANGLE turns its MTLSharedEvent fences (feature hasEvents) off on NVIDIA GPUs
// (crbug.com/1136673), which drops GL_ARB_sync. On Kepler (GTX 600/700) every WebGL context in Safari was created lost:
// getContext returned a context whose isContextLost() was already true (CONTEXT_LOST_WEBGL), nothing logged. This loads
// WebKit's libANGLE-shared into itself (the shim treats calls from it as WebKit's), creates WebGL-style contexts as WebKit
// does (Metal display with WebKit's feature list, WebGL compatibility, robust init, no client arrays, no implicit binds),
// checks that GL_ARB_sync is there for both, and then that ANGLE's fences on this GPU work: glFenceSync waited with
// glClientWaitSync, flushed and polled the way WebGL pages poll SYNC_STATUS, and EGL fences; none may time out.
// Tahoe's WebKit ANGLE doesn't offer GL_ARB_sync at all, with its fences on (GL_OES_EGL_sync, GL_NV_fence and
// EGL_KHR_fence_sync there; R9 M370X), and Tahoe's Safari makes WebGL contexts without it; what hasEvents off takes away is
// all four, so a context fails only when the other three are missing too.
// Stock OCLP on Kepler: FAIL (no GL_ARB_sync). Fixed: PASS. Other GPUs have hasEvents on already: PASS either way.
// SKIP without WebKit's ANGLE.
#import "repro.h"
#include <dlfcn.h>

typedef void *P;
typedef int32_t I;
typedef uint32_t U;
typedef intptr_t A;
static void *angle;
#define F(ret, name, ...) static ret (*name)(__VA_ARGS__);
F(P, EGL_GetPlatformDisplay, U, P, const A *) F(U, EGL_Initialize, P, I *, I *) F(U, EGL_ChooseConfig, P, const I *, P *, I, I *)
F(P, EGL_CreateContext, P, P, P, const I *) F(U, EGL_MakeCurrent, P, P, P, P) F(U, EGL_BindAPI, U) F(const char *, EGL_QueryString, P, I)
F(P, EGL_CreateSync, P, U, const A *) F(I, EGL_ClientWaitSync, P, P, I, uint64_t) F(U, EGL_DestroySync, P, P) F(U, EGL_DestroyContext, P, P)
F(const char *, GL_GetString, U) F(void, GL_RequestExtensionANGLE, const char *) F(U, GL_GetError, void) F(void, GL_GenRenderbuffers, I, U *)
F(void, GL_BindRenderbuffer, U, U) F(void, GL_RenderbufferStorage, U, U, I, I) F(void, GL_GenFramebuffers, I, U *) F(void, GL_BindFramebuffer, U, U)
F(void, GL_FramebufferRenderbuffer, U, U, U, U) F(void, GL_Viewport, I, I, I, I) F(void, GL_ClearColor, float, float, float, float)
F(void, GL_Clear, U) F(void, GL_Flush, void) F(P, GL_FenceSync, U, U) F(U, GL_ClientWaitSync, P, U, uint64_t) F(void, GL_DeleteSync, P)
F(void, GL_GetSynciv, P, U, I, I *, I *)
#define L(name) if (!(name = dlsym(angle, #name))) return SKIP(bug, "WebKit's ANGLE has no " #name);

static int has(const char *list, const char *name) {
    size_t n = strlen(name);
    for (const char *p = list; list && (p = strstr(p, name)); p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || !p[n])) return 1;
    return 0;
}

int main(void) {
    @autoreleasepool {
        const char *bug = "s69-safari-webgl-arb-sync";
        MTLCreateSystemDefaultDevice();  // as WebCore does in Safari's GPU process before ANGLE starts
        angle = dlopen("/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/"
                       "libANGLE-shared.dylib", RTLD_NOW);
        if (!angle) return SKIP(bug, "no WebKit ANGLE (libANGLE-shared.dylib)");
        L(EGL_GetPlatformDisplay) L(EGL_Initialize) L(EGL_ChooseConfig) L(EGL_CreateContext) L(EGL_MakeCurrent) L(EGL_BindAPI) L(EGL_QueryString)
        L(EGL_CreateSync) L(EGL_ClientWaitSync) L(EGL_DestroySync) L(EGL_DestroyContext) L(GL_GetString) L(GL_RequestExtensionANGLE) L(GL_GetError)
        L(GL_GenRenderbuffers) L(GL_BindRenderbuffer) L(GL_RenderbufferStorage) L(GL_GenFramebuffers) L(GL_BindFramebuffer)
        L(GL_FramebufferRenderbuffer) L(GL_Viewport) L(GL_ClearColor) L(GL_Clear) L(GL_Flush) L(GL_FenceSync) L(GL_ClientWaitSync) L(GL_DeleteSync)
        L(GL_GetSynciv)
        static const char *const disabledFeatures[] = {"enableInMemoryMtlLibraryCache", "alwaysPreferStagedTextureUploads", NULL};  // WebKit's
        const A displayAttributes[] = {0x3203, 0x3489, 0x3467, (A)disabledFeatures, 0x3038};  // Metal; EGL_FEATURE_OVERRIDES_DISABLED_ANGLE
        P display = EGL_GetPlatformDisplay(0x3202, NULL, displayAttributes);
        I major, minor, configs = 0;
        if (!display || !EGL_Initialize(display, &major, &minor)) return FAIL(bug, "ANGLE's Metal display didn't initialize");
        const I configAttributes[] = {0x3040, 0x0004, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3025, 0, 0x3026, 0, 0x3038};  // WebKit's
        P config = NULL;
        EGL_ChooseConfig(display, configAttributes, &config, 1, &configs);
        if (configs != 1) return FAIL(bug, "no EGL config for WebKit's attributes");
        EGL_BindAPI(0x30A0);
        P context = NULL;
        const char *renderer = "?";
        int noARBSync = 0;
        for (int webgl = 1; webgl <= 2; webgl++) {
            // EGL_CONTEXT_CLIENT_VERSION, [EGL_CONTEXT_OPENGL_BACKWARDS_COMPATIBLE_ANGLE false,] WEBGL_COMPATIBILITY, ROBUST_RESOURCE_INITIALIZATION,
            // CLIENT_ARRAYS_ENABLED false, BIND_GENERATES_RESOURCE false: GraphicsContextGLCocoa::platformInitializeContext
            const I webgl1[] = {0x3098, 2, 0x3483, 0, 0x33AC, 1, 0x3453, 1, 0x3452, 0, 0x33AD, 0, 0x3038};
            const I webgl2[] = {0x3098, 3, 0x33AC, 1, 0x3453, 1, 0x3452, 0, 0x33AD, 0, 0x3038};
            if (context) EGL_MakeCurrent(display, NULL, NULL, NULL), EGL_DestroyContext(display, context);
            context = EGL_CreateContext(display, config, NULL, webgl == 1 ? webgl1 : webgl2);
            if (!context || !EGL_MakeCurrent(display, NULL, NULL, context)) return FAIL(bug, "WebGL %d context: not created", webgl);
            renderer = GL_GetString(0x1F01) ?: "?";
            const char *extensions = GL_GetString(0x1F03), *requestable = GL_GetString(0x93A8);  // GL_REQUESTABLE_EXTENSIONS_ANGLE
            if (!has(extensions, "GL_ARB_sync") && !has(requestable, "GL_ARB_sync")) {
                if (!has(extensions, "GL_OES_EGL_sync") && !has(extensions, "GL_NV_fence") && !has(EGL_QueryString(display, 0x3055), "EGL_KHR_fence_sync"))
                    return FAIL(bug, "%s: WebGL %d context has no GL_ARB_sync, so WebKit fails every WebGL context (created lost)", renderer, webgl);
                noARBSync = 1;  // this ANGLE build doesn't offer it, fences on (Tahoe's WebKit)
            }
            if (!has(extensions, "GL_ARB_sync") && !noARBSync) GL_RequestExtensionANGLE("GL_ARB_sync");
        }
        // ANGLE's fences on this GPU: 2048x2048 clears, then a fence; even ones waited on, odd ones flushed and polled.
        U renderbuffer, framebuffer;
        GL_GenRenderbuffers(1, &renderbuffer);
        GL_BindRenderbuffer(0x8D41, renderbuffer);
        GL_RenderbufferStorage(0x8D41, 0x8058, 2048, 2048);  // RGBA8
        GL_GenFramebuffers(1, &framebuffer);
        GL_BindFramebuffer(0x8D40, framebuffer);
        GL_FramebufferRenderbuffer(0x8D40, 0x8CE0, 0x8D41, renderbuffer);
        GL_Viewport(0, 0, 2048, 2048);
        int waited = 0, polled = 0, eglFences = 0, timeouts = 0;
        for (int i = 0; i < 200; i++) {
            for (int c = 0; c < 4; c++) GL_ClearColor(i & 1, c / 4.0f, 0, 1), GL_Clear(0x4000);
            P sync = GL_FenceSync(0x9117, 0);  // GL_SYNC_GPU_COMMANDS_COMPLETE
            if (!sync) return FAIL(bug, "%s: glFenceSync returned no sync (GL error 0x%x)", renderer, GL_GetError());
            if (i % 2 == 0) {
                U r = GL_ClientWaitSync(sync, 1, 2000000000ull);  // GL_SYNC_FLUSH_COMMANDS_BIT, 2 s
                if (r == 0x911A || r == 0x911C) waited++; else timeouts++;  // ALREADY_SIGNALED, CONDITION_SATISFIED
            } else {
                GL_Flush();
                I status = 0, length = 0;
                NSDate *start = [NSDate date];
                while (status != 0x9119 && -start.timeIntervalSinceNow < 2.0) {  // GL_SIGNALED
                    GL_GetSynciv(sync, 0x9114, 1, &length, &status);  // GL_SYNC_STATUS
                    if (status != 0x9119) usleep(200);
                }
                if (status == 0x9119) polled++; else timeouts++;
            }
            GL_DeleteSync(sync);
        }
        if (has(EGL_QueryString(display, 0x3055), "EGL_KHR_fence_sync"))
            for (int i = 0; i < 50; i++) {
                GL_Clear(0x4000);
                P sync = EGL_CreateSync(display, 0x30F9, NULL);  // EGL_SYNC_FENCE_KHR
                if (sync && EGL_ClientWaitSync(display, sync, 1, 2000000000ull) == 0x30F6) eglFences++; else timeouts++;  // CONDITION_SATISFIED
                if (sync) EGL_DestroySync(display, sync);
            }
        if (timeouts || GL_GetError())
            return FAIL(bug, "%s: %d of ANGLE's fences never signaled (waited %d, polled %d, EGL %d)", renderer, timeouts, waited, polled, eglFences);
        return PASS(bug, "%s: WebGL 1 and 2 contexts have %s; 200 fences (%d waited, %d flushed and polled) and %d EGL fences signaled",
                    renderer, noARBSync ? "ANGLE's fences (this WebKit's ANGLE offers no GL_ARB_sync)" : "GL_ARB_sync", waited, polled, eglFences);
    }
}
