//
//  gl_bridge.m — EGL 경로 (GL4ES / MetalANGLE).
//  PojavLauncher iOS 의 ctxbridges/gl_bridge.m 을 옮긴 것.
//
//  데스크톱 GL 호출을 ANGLE(Metal 백엔드)이나 GL4ES 가 받아 화면에 그린다. 둘 다 EGL 을
//  노출하므로 같은 코드로 다룰 수 있고, 차이는 dlopen 할 dylib 이름뿐이다.
//
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>

#include "bridge_tbl.h"
#include "../flame_environ.h"

static EGLDisplay g_EglDisplay;
static egl_library handle;

/// 렌더러 dylib 을 먼저 보고, 없으면 ANGLE 의 libEGL 에서 찾는다.
///
/// 렌더러마다 egl* 을 내보내는 정도가 다르다:
///   - libgl4es_114.dylib      gl* 만 (egl* 0개)      → libEGL 로 폴백
///   - libtinygl4angle.dylib   gl* 51개, egl* 0개     → libEGL 로 폴백
///   - libmobileglues.dylib    gl* 2781개, egl* 49개  → **자기 것을 써야 한다**
/// MobileGlues 는 호스트 EGL 을 감싸서 컨텍스트를 직접 관리하므로, 그 위를 건너뛰고
/// ANGLE 의 egl* 을 부르면 MobileGlues 가 초기화되지 않는다.
static void *g_rendererDL, *g_eglDL;

/// 렌더러가 자기 egl* 을 들고 있는가 — 즉 데스크톱 GL 을 직접 흉내내는 프론트엔드인가.
/// 지금은 MobileGlues 만 해당한다. 컨텍스트 속성을 어떻게 줄지가 여기서 갈린다.
static BOOL g_rendererOwnsEGL;

static void *egl_sym(const char *name) {
    void *fn = g_rendererDL ? dlsym(g_rendererDL, name) : NULL;
    return fn ? fn : dlsym(g_eglDL, name);
}

static void dlsym_EGL(void) {
    // ⚠️ MetalANGLE 은 프레임워크 두 개(libEGL / libGLESv2)로 나뉘어 있고, 렌더러 shim 은
    //    그걸 링크하지 않고 dlsym(RTLD_DEFAULT) 로 찾는다. 그래서 **먼저** 전역으로 열어둬야
    //    한다 — 순서가 바뀌면 eglGetDisplay 부터 NULL 이 나온다.
    //
    // ⚠️ 예전에는 여기서 tinygl4angle 을 이름째 박아 열었다. 그러면 MobileGlues 를 골라도
    //    ANGLE shim 의 gl* 51 개가 같이 전역에 올라간다 — 먼저 올라간 쪽이 RTLD_DEFAULT
    //    검색에서 이기므로 순서에 기대는 코드가 된다. 고른 렌더러만 연다.
    const char *rendererName = getenv("POJAV_RENDERER");
    if (rendererName && *rendererName) {
        char path[512];
        snprintf(path, sizeof(path), "@rpath/%s", rendererName);
        g_rendererDL = dlopen(path, RTLD_GLOBAL);
    }
    g_rendererOwnsEGL = (g_rendererDL && dlsym(g_rendererDL, "eglCreateContext") != NULL);
    dlopen("@rpath/libGLESv2.framework/libGLESv2", RTLD_GLOBAL);

    g_eglDL = dlopen("@rpath/libEGL.framework/libEGL", RTLD_GLOBAL);
    NSCAssert(g_eglDL != NULL, @"libEGL 을 열지 못했습니다: %s", dlerror());

    handle.eglBindAPI = egl_sym("eglBindAPI");
    handle.eglChooseConfig = egl_sym("eglChooseConfig");
    handle.eglCreateContext = egl_sym("eglCreateContext");
    handle.eglCreateWindowSurface = egl_sym("eglCreateWindowSurface");
    handle.eglDestroyContext = egl_sym("eglDestroyContext");
    handle.eglDestroySurface = egl_sym("eglDestroySurface");
    handle.eglGetConfigAttrib = egl_sym("eglGetConfigAttrib");
    handle.eglGetCurrentContext = egl_sym("eglGetCurrentContext");
    handle.eglGetDisplay = egl_sym("eglGetDisplay");
    handle.eglGetError = egl_sym("eglGetError");
    handle.eglGetPlatformDisplay = egl_sym("eglGetPlatformDisplay");
    handle.eglInitialize = egl_sym("eglInitialize");
    handle.eglMakeCurrent = egl_sym("eglMakeCurrent");
    handle.eglSwapBuffers = egl_sym("eglSwapBuffers");
    handle.eglReleaseThread = egl_sym("eglReleaseThread");
    handle.eglSwapInterval = egl_sym("eglSwapInterval");
    handle.eglTerminate = egl_sym("eglTerminate");
    handle.eglGetCurrentSurface = egl_sym("eglGetCurrentSurface");
}

static bool gl_init(void) {
    dlsym_EGL();

    g_EglDisplay = handle.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_EglDisplay == EGL_NO_DISPLAY) {
        NSLog(@"[FlameGL] eglGetDisplay 가 EGL_NO_DISPLAY 를 반환했습니다");
        return false;
    }
    if (!handle.eglInitialize(g_EglDisplay, NULL, NULL)) {
        NSLog(@"[FlameGL] eglInitialize 실패: 0x%x", handle.eglGetError());
        return false;
    }
    return true;
}

static gl_render_window_t *gl_init_context(gl_render_window_t *share) {
    gl_render_window_t *bundle = calloc(1, sizeof(gl_render_window_t));

    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_NONE
    };

    EGLint num_configs, vid;
    if (!handle.eglChooseConfig(g_EglDisplay, attribs, &bundle->config, 1, &num_configs)) {
        NSLog(@"[FlameGL] eglChooseConfig 실패: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    if (!handle.eglGetConfigAttrib(g_EglDisplay, bundle->config, EGL_NATIVE_VISUAL_ID, &vid)) {
        NSLog(@"[FlameGL] eglGetConfigAttrib 실패: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    // 렌더러가 무엇이든 데스크톱 OpenGL 로 바인딩한다 — 마인크래프트가 그걸 기대한다.
    if (!handle.eglBindAPI(EGL_OPENGL_API)) {
        NSLog(@"[FlameGL] eglBindAPI 실패: 0x%x", handle.eglGetError());
    }

    bundle->surface = handle.eglCreateWindowSurface(
        g_EglDisplay, bundle->config, (__bridge EGLNativeWindowType)flameSurfaceLayer, NULL);
    if (!bundle->surface) {
        NSLog(@"[FlameGL] eglCreateWindowSurface 실패: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    // ⚠️ EGL_CONTEXT_CLIENT_VERSION 은 **ES 용** 속성이고, 값이 EGL_CONTEXT_MAJOR_VERSION
    //    (0x3098)과 같다. 데스크톱 GL 을 직접 흉내내는 렌더러에게 3 을 주면 "GL 3.0 을
    //    달라"는 뜻이 되고, MobileGlues 는 정직하게 3.0 을 준 뒤 그 값을
    //    glGetIntegerv(GL_MAJOR/MINOR_VERSION) 으로 돌려준다.
    //
    //    LWJGL 은 그 정수를 **먼저** 믿고 지원 버전 집합을 만든다(opengl/GL.java).
    //    3.0 이면 "OpenGL33" 이 집합에 안 들어가고, GLCapabilities.check_GL33 은
    //    첫 줄에서 돌아서며 GL 3.3 진입점을 **하나도 매핑하지 않는다**. MobileGlues 가
    //    glGenSamplers 를 멀쩡히 내보내는데도 포인터가 0 이라, 마인크래프트 26.2 가
    //    부팅 중 죽었다:
    //      FATAL ERROR in native method: … at org.lwjgl.opengl.GL33C.nglGenSamplers
    //      at com.mojang.blaze3d.opengl.GlSampler.<init>
    //
    //    비워 두면 렌더러가 자기 기본값을 쓴다 (MobileGlues 는 GL 4.0 — glGetString 으로
    //    이미 그렇게 광고하던 값이다). 덤으로 사용자의 customGLVersion 설정도 이제
    //    먹는다 — 여태 우리가 하드코딩한 3 이 그걸 덮어쓰고 있었다.
    //
    //    ANGLE 의 EGL 로 바로 가는 렌더러(gl4es 등)에는 ES 3 이 맞는 요청이므로 그대로 둔다.
    const EGLint es_attribs[]      = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    const EGLint desktop_attribs[] = { EGL_NONE };
    const EGLint *ctx_attribs = g_rendererOwnsEGL ? desktop_attribs : es_attribs;

    bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config,
                                              share ? share->context : EGL_NO_CONTEXT, ctx_attribs);
    if (!bundle->context) {
        NSLog(@"[FlameGL] eglCreateContext 실패: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    return bundle;
}

/// LWJGL 이 실제로 보게 될 GL 버전을 한 번 찍는다.
///
/// LWJGL 은 glGetIntegerv(GL_MAJOR/MINOR_VERSION) **정수**를 먼저 믿고 지원 버전
/// 집합을 만든다. 그 값이 3.0 이면 GL 3.3+ 진입점을 하나도 매핑하지 않아서
/// 마인크래프트 26.2 가 glGenSamplers 널 포인터로 죽는다. 문자열과 정수가
/// 어긋나 있는지 눈으로 봐야 한다.
static void flame_logGLVersion(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    const unsigned char *(*p_getString)(unsigned) =
        (void *)(g_rendererDL ? dlsym(g_rendererDL, "glGetString") : NULL) ?: dlsym(RTLD_DEFAULT, "glGetString");
    void (*p_getIntegerv)(unsigned, int *) =
        (void *)(g_rendererDL ? dlsym(g_rendererDL, "glGetIntegerv") : NULL) ?: dlsym(RTLD_DEFAULT, "glGetIntegerv");

    int major = -1, minor = -1;
    if (p_getIntegerv) {
        p_getIntegerv(0x821B /* GL_MAJOR_VERSION */, &major);
        p_getIntegerv(0x821C /* GL_MINOR_VERSION */, &minor);
    }
    const unsigned char *versionString = p_getString ? p_getString(0x1F02 /* GL_VERSION */) : NULL;

    printf("[FlameGL] 렌더러자체EGL=%d  GL_VERSION 문자열=\"%s\"  정수=%d.%d\n",
           (int)g_rendererOwnsEGL, versionString ? (const char *)versionString : "(없음)", major, minor);
    fflush(stdout);
}

static void gl_make_current(gl_render_window_t *bundle) {
    if (!bundle) {
        if (handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            currentBundle = NULL;
        }
        return;
    }
    if (handle.eglMakeCurrent(g_EglDisplay, bundle->surface, bundle->surface, bundle->context)) {
        currentBundle = (basic_render_window_t *)bundle;
        flame_logGLVersion();
    } else {
        NSLog(@"[FlameGL] eglMakeCurrent 실패: 0x%x", handle.eglGetError());
    }
}

static void gl_swap_buffers(void) {
    if (!currentBundle) return;
    if (!handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface) &&
        handle.eglGetError() == EGL_BAD_SURFACE) {
        NSLog(@"[FlameGL] eglSwapBuffers 실패: 0x%x", handle.eglGetError());
    }
}

static void gl_swap_interval(int swapInterval) {
    handle.eglSwapInterval(g_EglDisplay, swapInterval);
}

static void gl_terminate(void) {
    if (!currentBundle) return;
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    handle.eglDestroySurface(g_EglDisplay, currentBundle->gl.surface);
    handle.eglDestroyContext(g_EglDisplay, currentBundle->gl.context);
    handle.eglTerminate(g_EglDisplay);
    handle.eglReleaseThread();
    free(currentBundle);
    currentBundle = NULL;
}

void set_gl_bridge_tbl(void) {
    br_init = gl_init;
    br_init_context = (br_init_context_t)gl_init_context;
    br_make_current = (br_make_current_t)gl_make_current;
    br_swap_buffers = gl_swap_buffers;
    br_swap_interval = gl_swap_interval;
    br_terminate = gl_terminate;
}
