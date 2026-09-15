//
//  flame_gl.m — 패치된 LWJGL 이 직접 호출하는 GL/윈도우 진입점.
//  PojavLauncher iOS 의 egl_bridge.m 을 옮긴 것.
//
//  ⚠️ 이 파일의 `pojav*` 함수들은 자바에서 이렇게 찾아간다:
//        new MacOSXLibraryDL("PojavLauncher", RTLD_DEFAULT) → apiGetFunctionAddress(…, "pojavInit")
//     즉 **프로세스 전역 심볼 테이블**에서 이름으로 찾는다. C 쪽에서 아무도 참조하지 않으므로
//     링커가 죽은 코드로 지워버릴 수 있어서, 전부 used + default visibility 를 붙였다.
//     (이 표시를 빼면 링크는 되지만 게임이 "pojavInit 를 찾을 수 없다"며 부팅 중 죽는다.)
//
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <stdatomic.h>

#include "flame_environ.h"
#include "ctxbridges/bridge_tbl.h"
#include "include/glfw_keycodes.h"

#define FLAME_EXPORT __attribute__((used, visibility("default")))

// bridge_tbl.h 전역의 단일 정의
bool (*br_init)(void);
br_init_context_t br_init_context;
br_make_current_t br_make_current;
void (*br_swap_buffers)(void);
void (*br_swap_interval)(int swapInterval);
void (*br_terminate)(void);
__thread basic_render_window_t *currentBundle;

void set_gl_bridge_tbl(void);
void set_osm_bridge_tbl(void);

static int clientAPI;

/// 실제로 고른 렌더러를 자바 쪽 시스템 프로퍼티에도 반영한다.
/// LWJGL 이 `org.lwjgl.opengl.libname` 을 보고 GL 함수 포인터를 어느 dylib 에서 가져올지 정한다.
static void JNI_LWJGL_changeRenderer(const char *value) {
    if (!runtimeJavaVMPtr) return;
    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring val = (*env)->NewStringUTF(env, value);
    jclass system = (*env)->FindClass(env, "java/lang/System");
    jmethodID setProperty = (*env)->GetStaticMethodID(
        env, system, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    (*env)->CallStaticObjectMethod(env, system, setProperty, key, val);
}

static int pojavInitOpenGL(void) {
    NSString *renderer = NSProcessInfo.processInfo.environment[@"POJAV_RENDERER"];
    if (renderer.length == 0 || [renderer isEqualToString:@"auto"]) {
        renderer = @RENDERER_NAME_GL4ES;
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
    }

    if ([renderer hasPrefix:@"libOSMesa"]) {
        // Zink: OSMesa 의 Gallium 드라이버로 zink 를 고르면 실제 래스터화는 MoltenVK 가 한다.
        setenv("GALLIUM_DRIVER", "zink", 1);
        set_osm_bridge_tbl();
    } else {
        set_gl_bridge_tbl();
    }

    JNI_LWJGL_changeRenderer(renderer.UTF8String);
    dlopen([NSString stringWithFormat:@"@rpath/%@", renderer].UTF8String, RTLD_GLOBAL);
    return !br_init();
}

FLAME_EXPORT int pojavInit(bool useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = true;
    // ⚠️ 큐 경로를 켜야 콜백이 게임의 glfwPollEvents 안에서만 불린다.
    //    끄면 UI 스레드에서 바로 불려 마인크래프트 내부 상태가 깨진다.
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

FLAME_EXPORT void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) clientAPI = value;
}

FLAME_EXPORT void *pojavCreateContext(basic_render_window_t *contextSrc) {
    if (clientAPI == GLFW_NO_API) {
        // 게임이 Vulkan 을 직접 쓰기로 했다 — 레이어를 그대로 넘긴다.
        return (__bridge void *)flameSurfaceLayer;
    }
    static BOOL inited = NO;
    if (!inited) {
        inited = YES;
        pojavInitOpenGL();
    }
    return br_init_context(contextSrc);
}

FLAME_EXPORT void *pojavGetCurrentContext(void) { return br_get_current(); }

FLAME_EXPORT void pojavMakeCurrent(basic_render_window_t *window) { br_make_current(window); }

FLAME_EXPORT void pojavSwapBuffers(void) {
    br_swap_buffers();
    // FPS 표시용 카운터. 첫 스왑이 곧 "첫 프레임이 나왔다" 신호라서 부팅 오버레이도 이걸 본다.
    atomic_fetch_add_explicit(&flameFrameCount, 1, memory_order_relaxed);
    flameHasRendered = true;
}

FLAME_EXPORT void pojavSwapInterval(int interval) {
    if (br_swap_interval) br_swap_interval(interval);
}

FLAME_EXPORT void pojavTerminate(void) {
    CallbackBridge_nativeSetInputReady(false);
    if (br_terminate) br_terminate();
}
