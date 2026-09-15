//
//  flame_glfw.m — GLFW ↔ JNI 입력 브릿지.
//  PojavLauncher iOS 의 input_bridge_v3.m 을 옮긴 것.
//
//  마인크래프트(LWJGL)는 GLFW 콜백으로 입력을 받는다. 패치된 lwjgl-glfw.jar 이
//  `glfwSetKeyCallback` 등을 부르면 아래 `Java_org_lwjgl_glfw_GLFW_nglfwSet*Callback`
//  네이티브가 콜백 함수 포인터를 받아 저장하고, 우리가 터치/키보드/패드에서 만든 이벤트를
//  그 포인터로 흘려보낸다.
//
//  ⚠️ 이벤트를 콜백으로 **직접** 부르지 않고 큐에 쌓는 경로(isUseStackQueueCall)가 있는 이유:
//     LWJGL3 는 glfwPollEvents() 안에서만 콜백이 불리길 기대한다. 렌더 스레드가 아닌
//     UI 스레드에서 콜백을 직접 부르면 마인크래프트 내부 상태가 깨진다.
//
#import <UIKit/UIKit.h>

#include <stdatomic.h>
#include <string.h>

#include "flame_environ.h"
#include "include/glfw_keycodes.h"

// 자바가 RTLD_DEFAULT 로 이름을 찾아가는 심볼들 — 링커가 죽은 코드로 지우지 못하게 한다.
#define FLAME_EXPORT __attribute__((used, visibility("default")))

// MARK: - 이벤트 큐

void flame_send_data(short type, int i1, int i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < FLAME_EVENT_QUEUE_SIZE - 1) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->i1 = i1;
        event->i2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void flame_send_data_float(short type, float f1, float f2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < FLAME_EVENT_QUEUE_SIZE - 1) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->f1 = f1;
        event->f2 = f2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

// MARK: - JNI 초기화

static void JNI_OnLoadGLFW(void) {
    jclass glfw = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    if (!glfw) {
        // 패치되지 않은 LWJGL — 여기서 죽이지 않고 로그만 남긴다(런처 UI 는 살아 있어야 한다).
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        NSLog(@"[FlameGLFW] org.lwjgl.glfw.GLFW 를 찾지 못했습니다 — 패치된 lwjgl-glfw.jar 인지 확인하세요");
        return;
    }
    vmGlfwClass = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, glfw);
    method_internalWindowSizeChanged = (*runtimeJNIEnvPtr)->GetStaticMethodID(
        runtimeJNIEnvPtr, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");

    jfieldID field = (*runtimeJNIEnvPtr)->GetStaticFieldID(
        runtimeJNIEnvPtr, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    if (field) {
        jobject buffer = (*runtimeJNIEnvPtr)->GetStaticObjectField(runtimeJNIEnvPtr, vmGlfwClass, field);
        keyDownBuffer = (*runtimeJNIEnvPtr)->GetDirectBufferAddress(runtimeJNIEnvPtr, buffer);
    } else {
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
    }
}

/// JVM 이 이 바이너리를 네이티브 라이브러리로 로드할 때 호출된다.
jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    runtimeJavaVMPtr = vm;
    JNIEnv *env;
    (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_4);
    runtimeJNIEnvPtr = env;
    JNI_OnLoadGLFW();
    return JNI_VERSION_1_4;
}

void JNI_OnUnload(JavaVM *vm, void *reserved) {
    runtimeJNIEnvPtr = NULL;
}

// MARK: - 콜백 등록 (LWJGL 이 부른다)

#define ADD_CALLBACK_WWIN(NAME)                                                              \
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(                   \
        JNIEnv *env, jclass cls, jlong window, jlong callbackptr) {                          \
    void **oldCallback = (void **)&GLFW_invoke_##NAME;                                       \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func *)(uintptr_t)callbackptr;                \
    return (jlong)(uintptr_t)*oldCallback;                                                   \
}

ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)
#undef ADD_CALLBACK_WWIN

// MARK: - 이벤트 펌프 (게임 스레드가 glfwPollEvents 에서 부른다)

static void handleFramebufferSizeJava(void *window, int w, int h) {
    if (GLFW_invoke_CursorEnter) GLFW_invoke_CursorEnter(window, 1);
    if (GLFW_invoke_WindowPos) GLFW_invoke_WindowPos(window, 0, 0);
    if (vmGlfwClass && method_internalWindowSizeChanged) {
        (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, vmGlfwClass,
                                                  method_internalWindowSizeChanged, (jlong)(uintptr_t)window, w, h);
    }
}

FLAME_EXPORT void pojavPumpEvents(void *window) {
    CallbackBridge_nativeSetInputReady(true);
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);

    if ((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;
        if (isUseStackQueueCall) GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }

    for (size_t i = 0; i < counter; i++) {
        GLFWInputEvent event = events[i];
        switch (event.type) {
            case EVENT_TYPE_CHAR:
                if (GLFW_invoke_Char) GLFW_invoke_Char(window, event.i1);
                break;
            case EVENT_TYPE_CHAR_MODS:
                if (GLFW_invoke_CharMods) GLFW_invoke_CharMods(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_KEY:
                if (GLFW_invoke_Key) GLFW_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;
            case EVENT_TYPE_MOUSE_BUTTON:
                if (GLFW_invoke_MouseButton) GLFW_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_SCROLL:
                if (GLFW_invoke_Scroll) GLFW_invoke_Scroll(window, event.f1, event.f2);
                break;
            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if (GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if (GLFW_invoke_WindowSize) GLFW_invoke_WindowSize(window, event.i1, event.i2);
                break;
            default:
                break;
        }
    }
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

FLAME_EXPORT void pojavRewindEvents(void) {
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

// MARK: - 커서 위치 (LWJGL 이 직접 읽는다)

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *env, jclass clazz, jlong window,
                                           jobject xpos, jobject ypos) {
    *(double *)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double *)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *env, jclass clazz, jlong window,
                                            jdoubleArray xpos, jdoubleArray ypos) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0, 1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0, 1, &cursorY);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *env, jclass clazz, jlong window,
                                          jdouble xpos, jdouble ypos) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv *env, jclass clazz, jlong window) {
    showingWindow = (long)window;
}

// MARK: - grab 상태

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(JNIEnv *env, jclass clazz,
                                                     jboolean grabbing, jfloat xset, jfloat yset) {
    isGrabbing = grabbing;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(JNIEnv *env, jclass clazz) {
    return isGrabbing;
}

JNIEXPORT jstring JNICALL
Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(JNIEnv *env, jclass clazz,
                                                   jint action, jstring copySrc) {
    // 1 = 복사, 그 외 = 붙여넣기 (PojavLauncher 와 같은 규약)
    if (action == 1) {
        if (copySrc) {
            const char *chars = (*env)->GetStringUTFChars(env, copySrc, NULL);
            NSString *text = @(chars);
            (*env)->ReleaseStringUTFChars(env, copySrc, chars);
            dispatch_async(dispatch_get_main_queue(), ^{ UIPasteboard.generalPasteboard.string = text; });
        }
        return NULL;
    }
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ text = UIPasteboard.generalPasteboard.string; });
    return (*env)->NewStringUTF(env, text.UTF8String ?: "");
}

// MARK: - 입력 주입 (Swift 쪽에서 부른다)

void CallbackBridge_nativeSetInputReady(bool inputReady) {
    isInputReady = inputReady;
    if (!inputReady) return;
    if (GLFW_invoke_FramebufferSize) {
        GLFW_invoke_FramebufferSize((void *)showingWindow, windowWidth, windowHeight);
    }
    if (GLFW_invoke_WindowSize) {
        GLFW_invoke_WindowSize((void *)showingWindow, windowWidth, windowHeight);
    }
}

/// 수식키 상태를 누적해 GLFW mods 비트를 만든다.
/// 마인크래프트는 Shift+클릭 같은 조합을 mods 로만 구분하므로, 키 이벤트마다 현재 상태를
/// 같이 실어 보내야 한다.
static char getKeyModifiers(int key, int action) {
    static char currMods;
    char mod;
    switch (key) {
        case GLFW_KEY_LEFT_SHIFT:   mod = GLFW_MOD_SHIFT; break;
        case GLFW_KEY_LEFT_CONTROL: mod = GLFW_MOD_CONTROL; break;
        case GLFW_KEY_LEFT_ALT:     mod = GLFW_MOD_ALT; break;
        case GLFW_KEY_CAPS_LOCK:    mod = GLFW_MOD_CAPS_LOCK; break;
        case GLFW_KEY_NUM_LOCK:     mod = GLFW_MOD_NUM_LOCK; break;
        default: return currMods;
    }
    if (action) currMods |= mod; else currMods &= ~mod;
    return currMods;
}

void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {
    if (GLFW_invoke_Key && isInputReady) {
        if (keyDownBuffer) keyDownBuffer[MAX(0, key - 31)] = (jbyte)action;
        if (mods == 0) mods = getKeyModifiers(key, action);

        if (isUseStackQueueCall) {
            flame_send_data(EVENT_TYPE_KEY, key, scancode, action, mods);
        } else {
            GLFW_invoke_Key((void *)showingWindow, key, scancode, action, mods);
        }
    }

    // 마인크래프트는 macOS 로 인식되면 Ctrl 대신 Command 를 기대한다.
    // (LWJGL 이 보고하는 플랫폼이 macOS 라, Ctrl 만 보내면 단축키가 안 먹는다)
    if (key == GLFW_KEY_LEFT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SUPER, 0, action, mods);
    } else if (key == GLFW_KEY_RIGHT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_RIGHT_SUPER, 0, action, mods);
    }
}

/// 글자 하나를 게임에 넣는다.
///
/// ⚠️ `Char` 와 `CharMods` **둘 다** 보내야 한다.
///    마인크래프트는 `InputConstants.setupKeyboardCallbacks` 에서
///    `glfwSetCharModsCallback` 만 등록한다 — Char 콜백은 NULL 이라
///    그것만 보내면 입력이 조용히 사라진다(채팅·서버 주소가 안 쳐지던 원인).
///    반대로 CharMods 를 안 쓰는 모드/버전도 있어 둘 다 흘린다.
bool CallbackBridge_nativeSendChar(jchar codepoint) {
    if (!isInputReady) return false;
    bool delivered = false;

    if (GLFW_invoke_Char) {
        if (isUseStackQueueCall) flame_send_data(EVENT_TYPE_CHAR, codepoint, 0, 0, 0);
        else GLFW_invoke_Char((void *)showingWindow, (unsigned int)codepoint);
        delivered = true;
    }
    if (GLFW_invoke_CharMods) {
        if (isUseStackQueueCall) flame_send_data(EVENT_TYPE_CHAR_MODS, codepoint, 0, 0, 0);
        else GLFW_invoke_CharMods((void *)showingWindow, (unsigned int)codepoint, 0);
        delivered = true;
    }
    return delivered;
}

void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y) {
    if (!GLFW_invoke_CursorPos || !isInputReady) return;

    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) { cursorX = x; cursorY = y; }
            break;
        case ACTION_MOVE:
            if (isGrabbing) { cursorX += x - cLastX; cursorY += y - cLastY; }
            else { cursorX = x; cursorY = y; }
            break;
        case ACTION_MOVE_MOTION:
            cursorX += x; cursorY += y;
            break;
    }

    if (!isUseStackQueueCall) {
        GLFW_invoke_CursorPos((void *)showingWindow, (double)cursorX, (double)cursorY);
    }
}

void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {
    if (!isInputReady || button == -1 || !GLFW_invoke_MouseButton) return;
    if (mods == 0) mods = getKeyModifiers(0, action);

    if (isUseStackQueueCall) {
        flame_send_data(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
    } else {
        GLFW_invoke_MouseButton((void *)showingWindow, button, action, mods);
    }
}

void CallbackBridge_nativeSendScreenSize(int width, int height) {
    windowWidth = width;
    windowHeight = height;
    if (!isInputReady) return;

    if (GLFW_invoke_FramebufferSize) {
        if (isUseStackQueueCall) flame_send_data(EVENT_TYPE_FRAMEBUFFER_SIZE, width, height, 0, 0);
        else GLFW_invoke_FramebufferSize((void *)showingWindow, width, height);
    }
    if (GLFW_invoke_WindowSize) {
        if (isUseStackQueueCall) flame_send_data(EVENT_TYPE_WINDOW_SIZE, width, height, 0, 0);
        else GLFW_invoke_WindowSize((void *)showingWindow, width, height);
    }
}

void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {
    if (!GLFW_invoke_Scroll || !isInputReady) return;
    if (isUseStackQueueCall) {
        flame_send_data_float(EVENT_TYPE_SCROLL, xoffset, yoffset, 0, 0);
    } else {
        GLFW_invoke_Scroll((void *)showingWindow, (double)xoffset, (double)yoffset);
    }
}

void CallbackBridge_pauseGameIfNeed(void) {
    if (!isGrabbing) return;
    CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
}
