#include "../include/jni.h"

//jfieldID colorValueID;

// java.awt.*
JNIEXPORT void JNICALL
Java_java_awt_AWTEvent_initIDs(JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Button_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Color_initIDs
  (JNIEnv *env, jclass clazz)
{
    //colorValueID = (*env)->GetFieldID(env, clazz, "value", "I");
}

JNIEXPORT void JNICALL
Java_java_awt_Component_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Container_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Checkbox_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_CheckboxMenuItem_initIDs
  (JNIEnv *env, jclass clazz)
{
}
JNIEXPORT void JNICALL
Java_java_awt_Choice_initIDs
  (JNIEnv *env, jclass clazz)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Cursor_initIDs
  (JNIEnv *env, jclass cls)
{
    
}

JNIEXPORT void JNICALL
Java_java_awt_Cursor_finalizeImpl(JNIEnv *env, jclass clazz, jlong pData)
{
    
}

JNIEXPORT void JNICALL
Java_java_awt_Dialog_initIDs
  (JNIEnv *env, jclass cls)
{
    
}

JNIEXPORT void JNICALL
Java_java_awt_Dimension_initIDs
  (JNIEnv *env, jclass cls)
{
    
}

JNIEXPORT void JNICALL
Java_java_awt_Event_initIDs(JNIEnv *env, jclass cls)
{
    
}

JNIEXPORT void JNICALL
Java_java_awt_FileDialog_initIDs
  (JNIEnv *env, jclass cls)
{

}

JNIEXPORT void JNICALL
Java_java_awt_FontMetrics_initIDs
  (JNIEnv *env, jclass clazz)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Frame_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Insets_initIDs(JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_KeyboardFocusManager_initIDs
  (JNIEnv *env, jclass cls)
{
    
}

JNIEXPORT void JNICALL
Java_java_awt_Label_initIDs
  (JNIEnv *env, jclass clazz)
{
}

JNIEXPORT void JNICALL Java_java_awt_Menu_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_MenuBar_initIDs
  (JNIEnv *env, jclass clazz)
{
}

JNIEXPORT void JNICALL
Java_java_awt_MenuComponent_initIDs(JNIEnv *env, jclass cls)
{
    
}

JNIEXPORT void JNICALL Java_java_awt_MenuItem_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Rectangle_initIDs
  (JNIEnv *env, jclass clazz)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Scrollbar_initIDs
  (JNIEnv *env, jclass cls)
{

}

JNIEXPORT void JNICALL Java_java_awt_ScrollPane_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_ScrollPaneAdjustable_initIDs
  (JNIEnv *env, jclass clazz)
{
}

JNIEXPORT void JNICALL
Java_java_awt_TextArea_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_TextField_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Toolkit_initIDs
  (JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL Java_java_awt_TrayIcon_initIDs(JNIEnv *env , jclass clazz)
{
}

JNIEXPORT void JNICALL
Java_java_awt_Window_initIDs
  (JNIEnv *env, jclass cls)
{
}

// java.awt.event.*
JNIEXPORT void JNICALL
Java_java_awt_AWTEvent_nativeSetSource(JNIEnv *env, jobject self, jobject newSource)
{
    // Maybe implement this?
}

JNIEXPORT void JNICALL
Java_java_awt_event_InputEvent_initIDs(JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_event_KeyEvent_initIDs(JNIEnv *env, jclass cls)
{
}

JNIEXPORT void JNICALL
Java_java_awt_event_MouseEvent_initIDs
  (JNIEnv *env, jclass clazz)
{
}

// sun.awt.SunToolkit
JNIEXPORT void JNICALL
Java_sun_awt_SunToolkit_closeSplashScreen
  (JNIEnv *env, jclass cls)
{
    
}
// sun.awt.UNIXToolkit
JNIEXPORT jboolean JNICALL
Java_sun_awt_UNIXToolkit_check_1gtk(JNIEnv *env, jclass klass, jint version) {
    return JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_sun_awt_UNIXToolkit_get_1gtk_1version(JNIEnv *env, jclass klass)
{
    // return GTK_ANY;
    return (jint) 1;
}

JNIEXPORT jboolean JNICALL
Java_sun_awt_UNIXToolkit_gtkCheckVersionImpl(JNIEnv *env, jobject this,
        jint major, jint minor, jint micro)
{
    return JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_sun_awt_UNIXToolkit_load_1gtk(JNIEnv *env, jclass klass, jint version,
                                                             jboolean verbose) {
    return JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_sun_awt_UNIXToolkit_load_1gtk_1icon(JNIEnv *env, jobject this,
        jstring filename)
{
    return JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_sun_awt_UNIXToolkit_load_1stock_1icon(JNIEnv *env, jobject this,
        jint widget_type, jstring stock_id, jint icon_size,
        jint text_direction, jstring detail)
{
    return JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_sun_awt_UNIXToolkit_nativeSync(JNIEnv *env, jobject this)
{

}

JNIEXPORT jboolean JNICALL
Java_sun_awt_UNIXToolkit_unload_1gtk(JNIEnv *env, jclass klass)
{
    return JNI_FALSE;
}




// ── JDK 8 전용: 글꼴 네이티브 ───────────────────────────────────────────────
//
// JDK 8 은 headful 일 때 글꼴 네이티브도 libawt_xawt 에서 찾는다(JDK 9+ 는 다른 곳으로 옮겼다).
// 여기 없으면 1.5.2 이하처럼 java.awt.Frame 을 직접 만드는 버전이
//   UnsatisfiedLinkError: java.awt.Font.initIDs()V
// 로 즉시 죽는다(실측). 진짜 구현은 같은 JRE 의 libawt_headless 에 있으니 그쪽으로 넘긴다.
// (JDK 17+ 는 앞서 올라온 라이브러리에서 먼저 찾으므로 이 함수들이 쓰이지 않는다)
#include <dlfcn.h>
#include <limits.h>
#include <string.h>

static void *flame_headless(const char *symbol) {
    static void *handle;
    if (!handle) {
        Dl_info info;
        if (!dladdr((void *)flame_headless, &info) || !info.dli_fname) return NULL;
        char path[PATH_MAX];
        strlcpy(path, info.dli_fname, sizeof path);   // <jre>/lib/libawt_xawt.dylib
        char *slash = strrchr(path, '/');
        if (!slash) return NULL;
        strlcpy(slash + 1, "libawt_headless.dylib", sizeof path - (size_t)(slash + 1 - path));
        handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (!handle) return NULL;
    }
    return dlsym(handle, symbol);
}

#define FLAME_FORWARD_VOID(name, params, args) \
    JNIEXPORT void JNICALL name params { \
        void (*f) params = flame_headless(#name); \
        if (f) f args; \
    }

FLAME_FORWARD_VOID(Java_java_awt_Font_initIDs, (JNIEnv *env, jclass cls), (env, cls))
FLAME_FORWARD_VOID(Java_sun_awt_FontDescriptor_initIDs, (JNIEnv *env, jclass cls), (env, cls))
FLAME_FORWARD_VOID(Java_sun_awt_PlatformFont_initIDs, (JNIEnv *env, jclass cls), (env, cls))
FLAME_FORWARD_VOID(Java_sun_font_FontConfigManager_getFontConfig,
                   (JNIEnv *env, jclass cls, jstring locale, jobject info, jobjectArray fonts, jboolean fallbacks),
                   (env, cls, locale, info, fonts, fallbacks))

JNIEXPORT jint JNICALL
Java_sun_font_FontConfigManager_getFontConfigAASettings(JNIEnv *env, jclass cls, jstring locale, jstring fcFamily)
{
    jint (*f)(JNIEnv *, jclass, jstring, jstring) = flame_headless(__func__);
    return f ? f(env, cls, locale, fcFamily) : -1;
}

JNIEXPORT jint JNICALL
Java_sun_font_FontConfigManager_getFontConfigVersion(JNIEnv *env, jclass cls)
{
    jint (*f)(JNIEnv *, jclass) = flame_headless(__func__);
    return f ? f(env, cls) : 0;
}

JNIEXPORT jstring JNICALL
Java_sun_awt_FcFontManager_getFontPathNative(JNIEnv *env, jobject self, jboolean noType1, jboolean isX11GE)
{
    jstring (*f)(JNIEnv *, jobject, jboolean, jboolean) = flame_headless(__func__);
    return f ? f(env, self, noType1, isX11GE) : (*env)->NewStringUTF(env, "");
}

// JDK 8 의 libfontmanager 는 X11 글꼴 함수(AWTCountFonts · AWTLoadFont 등 17개)를 **이름으로**
// (flat lookup) 찾는다. 데스크톱에서는 libawt_xawt 가 내보내는데 이 스텁에는 없어서 주소 0 으로
// 묶였고, NativeFont.fontExists 에서 pc=0 으로 죽었다(실측, 1.5.2). headless 판이 17개를 모두
// 갖고 있으므로 스텁이 올라오는 순간 **전역(RTLD_GLOBAL)** 으로 같이 올린다. libfontmanager 는
// 그 뒤에 올라온다(FontManagerNativeLibrary 가 awt → fontmanager 순으로 연다).
// JDK 9+ 에는 이 경로가 없으므로 JDK 8(lib/jli/ 배치)일 때만 한다.
#include <stdio.h>
#include <unistd.h>

__attribute__((constructor)) static void flame_exposeHeadlessFontsForJDK8(void) {
    Dl_info info;
    if (!dladdr((void *)flame_exposeHeadlessFontsForJDK8, &info) || !info.dli_fname) return;
    char dir[PATH_MAX];
    strlcpy(dir, info.dli_fname, sizeof dir);
    char *slash = strrchr(dir, '/');
    if (!slash) return;
    *slash = '\0';
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/jli/libjli.dylib", dir);
    if (access(path, F_OK) != 0) return;
    snprintf(path, sizeof path, "%s/libawt_headless.dylib", dir);
    dlopen(path, RTLD_NOW | RTLD_GLOBAL);
}
