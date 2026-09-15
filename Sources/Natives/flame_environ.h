//
//  flame_environ.h — 네이티브 브릿지가 공유하는 전역 상태.
//  PojavLauncher iOS 의 environ.h 를 옮긴 것.
//
//  ⚠️ 원본은 헤더에 `extern` 없이 전역을 선언했다(C 임시 정의). Xcode 11 부터 기본이
//     -fno-common 이라 그대로 두면 중복 심볼로 링크가 깨진다 — 여기서는 extern 선언 +
//     flame_environ.m 의 단일 정의로 바꿨다.
//
#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>
#include "include/jni.h"

typedef struct {
    short type;
    union { int i1; float f1; };
    union { int i2; float f2; };
    short i3;
    short i4;
} GLFWInputEvent;

typedef void GLFW_invoke_Char_func(void *window, unsigned int codepoint);
typedef void GLFW_invoke_CharMods_func(void *window, unsigned int codepoint, int mods);
typedef void GLFW_invoke_CursorEnter_func(void *window, int entered);
typedef void GLFW_invoke_CursorPos_func(void *window, double xpos, double ypos);
typedef void GLFW_invoke_FramebufferSize_func(void *window, int width, int height);
typedef void GLFW_invoke_Key_func(void *window, int key, int scancode, int action, int mods);
typedef void GLFW_invoke_MouseButton_func(void *window, int button, int action, int mods);
typedef void GLFW_invoke_Scroll_func(void *window, double xoffset, double yoffset);
typedef void GLFW_invoke_WindowPos_func(void *window, int x, int y);
typedef void GLFW_invoke_WindowSize_func(void *window, int width, int height);

#define FLAME_EVENT_QUEUE_SIZE 8000

extern atomic_size_t eventCounter;
extern GLFWInputEvent events[FLAME_EVENT_QUEUE_SIZE];
extern double cursorX, cursorY, cLastX, cLastY;

extern jmethodID method_internalWindowSizeChanged;
extern jclass vmGlfwClass;
extern jboolean isGrabbing;
extern jbyte *keyDownBuffer;
extern JavaVM *runtimeJavaVMPtr;
extern JNIEnv *runtimeJNIEnvPtr;
extern long showingWindow;
extern bool isInputReady, isUseStackQueueCall;
extern int windowWidth, windowHeight;
extern float resolutionScale;

/// 게임이 그려지는 레이어. Swift 가 FlameNativeSetSurfaceLayer 로 넣는다.
extern CALayer *_Nullable flameSurfaceLayer;

/// 스왑 카운터 — FPS 표시용.
extern atomic_int flameFrameCount;
extern bool flameHasRendered;

#define ADD_CALLBACK_WWIN(NAME) extern GLFW_invoke_##NAME##_func *GLFW_invoke_##NAME;
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

// 컨트롤 액션 (PojavLauncher 와 동일)
#define ACTION_DOWN 0
#define ACTION_UP 1
#define ACTION_MOVE 2
#define ACTION_MOVE_MOTION 3

// GLFW 이벤트 타입
#define EVENT_TYPE_CHAR 1000
#define EVENT_TYPE_CHAR_MODS 1001
#define EVENT_TYPE_CURSOR_ENTER 1002
#define EVENT_TYPE_CURSOR_POS 1003
#define EVENT_TYPE_FRAMEBUFFER_SIZE 1004
#define EVENT_TYPE_KEY 1005
#define EVENT_TYPE_MOUSE_BUTTON 1006
#define EVENT_TYPE_SCROLL 1007
#define EVENT_TYPE_WINDOW_POS 1008
#define EVENT_TYPE_WINDOW_SIZE 1009

// 렌더러 dylib 이름 — Renderer.swift 의 libglName 과 반드시 일치해야 한다.
#define RENDERER_NAME_GL4ES "libgl4es_114.dylib"
#define RENDERER_NAME_MTL_ANGLE "libtinygl4angle.dylib"
#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"
#define RENDERER_NAME_MOBILEGLUES "libmobileglues.dylib"

void flame_send_data(short type, int i1, int i2, short i3, short i4);
void flame_send_data_float(short type, float f1, float f2, short i3, short i4);
void CallbackBridge_nativeSetInputReady(bool inputReady);
void CallbackBridge_nativeSendScreenSize(int width, int height);
