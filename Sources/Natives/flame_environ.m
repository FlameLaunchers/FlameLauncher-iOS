//  flame_environ.m — flame_environ.h 전역의 단일 정의.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include "flame_environ.h"

atomic_size_t eventCounter;
GLFWInputEvent events[FLAME_EVENT_QUEUE_SIZE];
double cursorX, cursorY, cLastX, cLastY;

jmethodID method_internalWindowSizeChanged;
jclass vmGlfwClass;
jboolean isGrabbing = JNI_FALSE;
jbyte *keyDownBuffer;
JavaVM *runtimeJavaVMPtr;
JNIEnv *runtimeJNIEnvPtr;
long showingWindow;
bool isInputReady = false;
bool isUseStackQueueCall = false;
int windowWidth, windowHeight;
float resolutionScale = 1.0f;

CALayer *flameSurfaceLayer;
atomic_int flameFrameCount;
bool flameHasRendered = false;

#define ADD_CALLBACK_WWIN(NAME) GLFW_invoke_##NAME##_func *GLFW_invoke_##NAME;
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
